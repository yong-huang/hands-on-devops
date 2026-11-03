#!/usr/bin/env bash
# =============================================================================
# 24 · 密钥治理（SOPS + age）— 主演示脚本
#
# 静态加密路线：密文入 git（键名明文可 review，值加密）→ CI 用 age 私钥解密
# → 泄漏面三重扫描（grep / git log / git diff）→ 密钥轮换（旧密钥失效新密钥可解）
# → SOPS(静态) vs Vault(动态) 选型矩阵。
#
# ./sops_age.sh keygen    age 密钥对（600 权限，gitignore 外置）
# ./sops_age.sh encrypt   明文 → 密文（encrypted_regex：键名明文值加密）+ 三重泄漏扫描
# ./sops_age.sh deploy    CI 视角：仅持私钥解密 → K8s Secret 生成 → 值一致性断言
# ./sops_age.sh gitdiff   两版密文的 git diff（review 看什么）+ git 历史无明文
# ./sops_age.sh rotate    密钥轮换：新 key 重加密 → 旧 key 解不开 → 新 key 可解
# ./sops_age.sh matrix    SOPS vs Vault 选型对比表
# ./sops_age.sh clean     清理运行时产物（密钥/密文全部重生成）
# ./sops_age.sh           # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

export SOPS_AGE_KEY_FILE="$PWD/tmp/key.txt"          # CI 视角：只有这一个文件是秘密
NEW_KEY="$PWD/tmp/key-new.txt"                       # 轮换演示用的第二把密钥
REPO="$PWD/tmp/git-probe"                            # 模拟 git 仓库（验证 diff/历史）
SECRETS="secrets/db-credentials.yaml"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }
must_contain() { grep -qE "$2" "$1" || fail "$3（$1 缺少 /$2/）"; ok "$3"; }

recipient() { grep "public key" "$SOPS_AGE_KEY_FILE" | awk '{print $NF}'; }

plant_plaintext() {  # 生成明文源（每次 clean 后由本函数复原，秘密值不入库）
    mkdir -p secrets
    cat > "$SECRETS" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: demo
type: Opaque
stringData:
  username: admin
  password: super-secret-password-2026
  endpoint: postgres.internal:5432
EOF
}

do_keygen() {
    step keygen "生成 age 密钥对（私钥 600，gitignore 外置）"
    mkdir -p tmp
    if [ ! -f "$SOPS_AGE_KEY_FILE" ]; then
        age-keygen -o "$SOPS_AGE_KEY_FILE" >/dev/null 2>&1
        note "[ok] 新密钥对生成"
    else
        note "[=] 密钥已存在（幂等）"
    fi
    chmod 600 "$SOPS_AGE_KEY_FILE"
    note "recipient: $(recipient | cut -c1-24)…"
    grep -qE "^tmp/$|key.txt" ../../.gitignore && note ".gitignore 已含 tmp/（私钥不入库）" \
        || note "[i] 确认 .gitignore 含 tmp/"
    ok "私钥就位（600），git 永远看不到它"
}

do_encrypt() {
    step encrypt "明文 → 密文（encrypted_regex：键名明文、值加密）"
    plant_plaintext
    sops --encrypt --age "$(recipient)" --in-place "$SECRETS"
    head -12 "$SECRETS" | sed 's/^/        /'
    # 三重泄漏扫描
    ! grep -rq "super-secret" "$SECRETS" || fail "密文里有明文密码"
    ok "工作区扫描：明文 0 命中"
    mkdir -p tmp/git-probe/secrets
    cp "$SECRETS" tmp/git-probe/secrets/ && cp .sops.yaml tmp/git-probe/
    ( cd tmp/git-probe && git init -q -b main && git add -A \
        && git -c user.email=lab@local -c user.name=lab commit -qm v1 >/dev/null )
    ! ( cd tmp/git-probe && git log -p | grep -q "super-secret" ) || fail "git 历史里有明文"
    ok "git 历史扫描：明文 0 命中（密文可安全入 git）"
}

do_deploy() {
    step deploy "CI 视角：持私钥解密 → K8s Secret 生成 → 值一致"
    [ -f "$SOPS_AGE_KEY_FILE" ] || fail "无私钥（CI 从安全通道取，绝不从 git）"
    local dec="tmp/db-decrypted.yaml"
    sops --decrypt "$SECRETS" > "$dec"
    must_contain "$dec" "super-secret-password-2026" "解密值与原值一致"
    # 用解密产物生成 K8s Secret（apply 形态，供 kubectl/kustomize 消费）
    kubectl create secret generic db-credentials \
        --from-literal=username="$(grep 'username:' "$dec" | awk '{print $2}')" \
        --from-literal=password="$(grep 'password:' "$dec" | awk '{print $2}')" \
        --namespace demo --dry-run=client -o yaml > tmp/db-secret.k8s.yaml 2>/dev/null \
        || python3 - "$dec" > tmp/db-secret.k8s.yaml <<'EOF'
import sys
vals = {}
for line in open(sys.argv[1]):
    if ':' in line and 'stringData' not in line and '#' not in line:
        k, _, v = line.partition(':')
        if k.strip() in ('username', 'password', 'endpoint'):
            vals[k.strip()] = v.strip()
print("""apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: demo
type: Opaque
stringData:""")
for k, v in vals.items():
    print(f"  {k}: {v}")
EOF
    # kubectl create secret 产物是 base64 data 形态——解码后断言原值
    local b64
    b64=$(grep 'password:' tmp/db-secret.k8s.yaml | awk '{print $2}')
    [ "$(echo "$b64" | base64 -d)" = "super-secret-password-2026" ] \
        || fail "K8s Secret 产物口令不一致"
    ok "K8s Secret 产物含正确口令（base64 解码断言）"
    rm -f "$dec"
    note "[i] 无 kubectl 集群场景：产物即部署输入（kustomize/flux 的 resources 引用）"
}

do_gitdiff() {
    step gitdiff "两版密文的 git diff（review 看什么）"
    rm -rf tmp/git-probe && mkdir -p tmp/git-probe/secrets
    cp "$SECRETS" tmp/git-probe/secrets/ && cp .sops.yaml tmp/git-probe/
    ( cd tmp/git-probe && git init -q -b main && git add -A \
        && git -c user.email=lab@local -c user.name=lab commit -qm v1 >/dev/null )
    sops --decrypt --in-place tmp/git-probe/"$SECRETS"
    sed -i '' 's/2026/2027/' tmp/git-probe/"$SECRETS"
    sops --encrypt --in-place tmp/git-probe/"$SECRETS"
    ( cd tmp/git-probe && git add -A \
        && git -c user.email=lab@local -c user.name=lab commit -qm v2 >/dev/null )
    ( cd tmp/git-probe && git diff HEAD~1 HEAD | grep -E "^[-+].*ENC" \
        | cut -c1-120 | sed 's/^/        /' )
    ok "键名明文、值密文逐行变化——reviewer 知道'哪个值变了'而看不到值"
    ( cd tmp/git-probe && git log -p | grep -q "super-secret" ) && fail "diff 过程泄漏明文" || ok "全过程（含历史）明文 0 命中"
}

do_rotate() {
    step rotate "密钥轮换：加新钥（并存）→ 新钥可解 → 移旧钥（旧钥失效）"
    # SOPS 原生轮换姿势（实测）：rotate 子命令 + add-age/rm-age 按公钥指纹操作，
    # 数据密钥不变——存量密文无需全量重写
    age-keygen -o "$NEW_KEY" >/dev/null 2>&1 && chmod 600 "$NEW_KEY"
    local new_rcp old_rcp
    new_rcp=$(grep "public key" "$NEW_KEY" | awk '{print $NF}')
    old_rcp=$(recipient)

    sops rotate -i --add-age "$new_rcp" "$SECRETS" 2>/dev/null
    note "已加入新 recipient（新旧并存）"
    SOPS_AGE_KEY_FILE="$NEW_KEY" sops --decrypt "$SECRETS" > tmp/rotated.yaml 2>/dev/null \
        || fail "新 key 解不开（add-age 失败）"
    must_contain tmp/rotated.yaml "super-secret-password-2026" "并存期：新 key 可解"
    SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --decrypt "$SECRETS" >/dev/null 2>&1 \
        && ok "并存期：旧 key 仍可解（迁移窗口内）" || fail "旧 key 反而解不开了"

    sops rotate -i --rm-age "$old_rcp" "$SECRETS" 2>/dev/null
    SOPS_AGE_KEY_FILE="$SOPS_AGE_KEY_FILE" sops --decrypt "$SECRETS" >/dev/null 2>&1 \
        && fail "旧 key 移除后仍能解（rm-age 未生效）"
    ok "迁移完成：旧 key 已失效（rm-age）"
    SOPS_AGE_KEY_FILE="$NEW_KEY" sops --decrypt "$SECRETS" > tmp/rotated.yaml 2>/dev/null \
        || fail "移除旧钥后新 key 反而解不开"
    must_contain tmp/rotated.yaml "super-secret-password-2026" "终态：新 key 全权解密"
    ok "轮换完成（生产动作：吊销旧 key 私钥 + 轮换后的密文入 git）"
}

do_matrix() {
    step matrix "SOPS(静态加密) vs Vault(动态注入) 选型边界"
    cat <<'EOF'
        ┌──────────────┬────────────────────────┬────────────────────────┐
        │ 维度          │ SOPS + age（本实验）     │ Vault                  │
        ├──────────────┼────────────────────────┼────────────────────────┤
        │ 模型          │ 静态：密文随 git 分发    │ 动态：运行时租借，短期凭证 │
        │ 事实源        │ git（密文即历史）        │ Vault 服务（审计中心）    │
        │ 解密位置      │ CI/本地（私钥持有者）    │ 应用运行时（AppRole/K8s SA）│
        │ 轮换          │ 重加密提交（本实验 rotate）│ 引擎自动轮换（DB 动态秘密）│
        │ 审计          │ git log（谁改了密文）    │ 精细到"谁在何时读了什么"  │
        │ 基建成本      │ 零（文件 + age 密钥）    │ 需部署/运维 Vault 集群   │
        │ 适用          │ 小团队/K8s 清单密钥      │ 多服务动态凭证/强审计需求 │
        └──────────────┴────────────────────────┴────────────────────────┘
        边界：都需要"解密时刻"的信任（CI runner 上有私钥/有 Vault token）——
        差别在泄露半径与审计粒度。与 labs/06 Vault 实验互为参照。
EOF
}

do_clean() {
    step clean "清理运行时产物（密钥/密文全部可由脚本重生成）"
    rm -rf tmp
    plant_plaintext
    rm -f "$SECRETS"
    note "[ok] 零残留（secrets/ 空目录保留；明文从不入库）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        keygen)  do_keygen ;;
        encrypt) do_keygen; do_encrypt ;;
        deploy)  do_deploy ;;
        gitdiff) do_gitdiff ;;
        rotate)  do_keygen; do_encrypt; do_rotate ;;
        matrix)  do_matrix ;;
        clean)   do_clean ;;
        all)
            do_keygen
            do_encrypt
            do_deploy
            do_gitdiff
            do_rotate
            do_matrix
            do_clean
            echo; echo "✅ 24 全部通过"
            ;;
        *) echo "可用: keygen | encrypt | deploy | gitdiff | rotate | matrix | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
