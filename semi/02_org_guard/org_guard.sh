#!/usr/bin/env bash
# semi/02_org_guard · 设计部门工作区与 IP 保护 · 生命周期总控
# 用法：./org_guard.sh up | verify | status | clean
#   up     平台配置演进（全局 server hooks 目录）→ 装 pre-receive → root token → 组树/用户/保护分支 bootstrap
#   verify 清单验收断言（真实 git push 三连：受限用户撞 main / 100MB 撞 hook / 小文件放行）
#   status 组树/成员/hook 现状速览
#   clean  删靶场与实验用户、卸 hook、回滚 01 gitlab.rb 的 hooks 段（组 semi 保留供后续项目用）
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE=".root-token"                       # 临时凭据，已 gitignore
PLATFORM_RB="../01_gitlab_up/configs/gitlab.rb" # 平台配置唯一真源（01 挂盖进容器）
HOOK_DST="/var/opt/gitlab/gitaly/custom_hooks/pre-receive"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 15 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

# ── 平台配置演进：01 的 gitlab.rb 追加全局 hooks 目录（幂等）────────────
ensure_platform_config() {
    if grep -q "custom_hooks_dir" "$PLATFORM_RB"; then
        echo "[  =] gitlab.rb 已含 custom_hooks_dir，跳过"
        return 0
    fi
    step config "平台配置演进：给 01 的 gitlab.rb 追加 server hooks 目录（Gitaly 全局）"
    cat >> "$PLATFORM_RB" <<'RB'

## ── Server hooks（02_org_guard 加装）：全局自定义钩子目录 ──────────────
## Gitaly 对每个仓库执行 push 时，会先跑 custom_hooks_dir 下的 pre-receive。
## 平台级 IP 保护：>50MB 的 blob 直推一律拒绝，逼大文件走 LFS（半导体内网纪律）。
gitaly['configuration'] = {
  hooks: {
    custom_hooks_dir: '/var/opt/gitlab/gitaly/custom_hooks',
  },
}
RB
    echo "[ok] 已追加，reconfigure 生效中（1-2 分钟，只此一次）"
    docker exec gitlab gitlab-ctl reconfigure > /tmp/org_guard_reconfigure.log 2>&1
    grep -q "custom_hooks_dir" <(docker exec gitlab cat /var/opt/gitlab/gitaly/config.toml) ||
        { echo "[fail] config.toml 未生效 custom_hooks_dir（见 /tmp/org_guard_reconfigure.log）"; exit 1; }
    ./../01_gitlab_up/scripts/healthcheck.sh   # reconfigure 后服务重启，等就绪
}

install_hook() {
    step hook "安装全局 pre-receive（custom_hooks/pre-receive.d/，>50MB 直推拦截）"
    # ⚠️ GitLab 19：全局 hook 必须放 <类型>.d/ 子目录（裸 pre-receive 文件不被扫描），
    #    且属主必须是 git（Gitaly 拒绝执行非 git 用户的 hook）；per-repo 旧式 custom_hooks/
    #    裸文件仍兼容但属"遗留通道"，平台级统一走全局目录。
    docker exec gitlab bash -c "rm -rf /var/opt/gitlab/gitaly/custom_hooks/pre-receive \
        && mkdir -p /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d"
    docker cp configs/pre-receive "gitlab:/var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/50-block-huge-blobs"
    docker exec gitlab bash -c "chown -R git:git /var/opt/gitlab/gitaly/custom_hooks \
        && chmod 755 /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/50-block-huge-blobs"
    pass "hook 已就位：${HOOK_DST}.d/50-block-huge-blobs（git 属主，对所有仓库生效）"
}

# ── root PAT：rails runner 造一个带 api 权限的 token（rails 直连 DB，不依赖密码）──
ensure_root_token() {
    step token "root PAT（semi-org-guard）"
    if [ -s "$TOKEN_FILE" ] &&
       [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/user")" = "200" ]; then
        echo "[  =] token 文件有效，复用"
        return 0
    fi
    docker exec gitlab rm -f /tmp/root_token.rb
    docker cp scripts/root_token.rb gitlab:/tmp/root_token.rb
    local tok
    tok=$(docker exec gitlab gitlab-rails runner /tmp/root_token.rb 2>/dev/null | tail -1)
    [ -n "$tok" ] || { echo "[fail] rails runner 未产出 token"; exit 1; }
    printf '%s' "$tok" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
    docker exec gitlab rm -f /tmp/root_token.rb
    echo "[ok] 新 token 已生成并缓存到 ${TOKEN_FILE}（gitignore 中）"
}

do_up() {
    ensure_platform_config
    install_hook
    ensure_root_token
    step bootstrap "组织与 IP 保护 apply（configs/org.yaml → API）"
    python3 scripts/bootstrap_org.py "$URL" "$(cat "$TOKEN_FILE")" configs/org.yaml
}

# ── 验收：真实 git push 三连（docs/cicd-semi.md 项目 2）────────────────
do_verify() {
    local FAILED=0
    [ -s "$TOKEN_FILE" ] || { echo "先跑 ./org_guard.sh up"; exit 1; }
    if [ "$(api "projects/semi%2Fip%2Fdesign%2Fpush-lab" | head -c 2)" != '{"' ]; then
        fail "push-lab 不存在——先跑 ./org_guard.sh up"; exit 1
    fi
    step verify "验收① 受限用户直推 main → 必须被拒"
    local tmp; tmp=$(mktemp -d)
    # bash 3.2 + set -u：EXIT 时 local 已出栈，用 ${tmp:-} 防误报
    trap 'rm -rf "${tmp:-}"' EXIT
    local PWD1; PWD1=$(python3 -c "import yaml;print(yaml.safe_load(open('configs/org.yaml'))['users'][0]['password'])")
    git clone -q "http://dev1:${PWD1}@localhost:28200/semi/ip/design/push-lab.git" "$tmp/repo"
    git -C "$tmp/repo" -c user.name=dev1 -c user.email=dev1@semi.local \
        commit -q --allow-empty -m "attempt: direct push to main"
    local out rc=0
    out=$(git -C "$tmp/repo" push origin main 2>&1) || rc=$?
    if [ "$rc" -ne 0 ] && echo "$out" | grep -qiE "protected branch"; then
        pass "dev1 直推 main 被拒（exit≠0 + protected branch 提示）"
        echo "$out" | grep -iE "protected branch" | head -1 | sed 's/^/         /'
    else
        fail "期望被拒（rc≠0 + protected branch），实际 rc=${rc}: $(echo "$out" | tail -1)"
        FAILED=1
    fi

    step verify "验收② 100MB 大文件直推 → server hook 必须拒绝并提示 LFS"
    git -C "$tmp/repo" checkout -qb "feature/big-$(date +%s)"
    dd if=/dev/urandom of="$tmp/repo/big.bin" bs=1048576 count=100 status=none
    git -C "$tmp/repo" add big.bin
    git -C "$tmp/repo" -c user.name=dev1 -c user.email=dev1@semi.local commit -qm "add big.bin"
    rc=0
    out=$(git -C "$tmp/repo" push origin HEAD 2>&1) || rc=$?
    if [ "$rc" -ne 0 ] && echo "$out" | grep -q "大文件请走 LFS"; then
        pass "100MB 直推被 pre-receive 拒绝且提示 LFS"
        echo "$out" | grep "pre-receive" | head -2 | sed 's/^/         /'
    else
        fail "期望 hook 拒绝（rc≠0 + LFS 提示），实际 rc=${rc}: $(echo "$out" | tail -2)"
        FAILED=1
    fi

    step verify "验收③ 普通小文件推 feature 分支 → 放行"
    # 从 main 切分支：若从②的失败分支头切，big.bin 会被一起带入（hook 拒得对，别冤枉它）
    git -C "$tmp/repo" checkout -qb "feature/small-$(date +%s)" main
    echo "small change $(date)" > "$tmp/repo/notes.md"
    git -C "$tmp/repo" add notes.md
    git -C "$tmp/repo" -c user.name=dev1 -c user.email=dev1@semi.local commit -qm "small file ok"
    if git -C "$tmp/repo" push -q origin HEAD 2>/dev/null; then
        pass "小文件推送成功（hook 放行 + 分支未保护）"
    else
        fail "小文件推送被拒（hook 误伤或权限配置错）"; FAILED=1
    fi

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 2 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "组树与成员（API）"
    python3 - "$URL" "$(cat "$TOKEN_FILE")" <<'PY'
import sys, gitlab
gl = gitlab.Gitlab(sys.argv[1], private_token=sys.argv[2])
for g in gl.groups.list(search='semi', get_all=True):
    print(f"  {g.full_path}")
    for m in g.members.list(get_all=True):
        print(f"    · {m.username} level={m.access_level}")
for p in gl.projects.list(search='push-lab', get_all=True):
    print(f"  项目 {p.path_with_namespace} (default={p.default_branch}, empty={p.empty_repo})")
PY
    step status "server hook"
    docker exec gitlab ls -l /var/opt/gitlab/gitaly/custom_hooks/ 2>/dev/null | tail -2
    docker stats --no-stream --format '  gitlab: {{.MemUsage}}' gitlab
}

# clean：只拆本实验装的东西（组 semi 留给项目 3+）
do_clean() {
    step clean "删除 push-lab 项目 + dev1 用户 + hook + gitlab.rb hooks 段"
    local tok hdr=""
    [ -s "$TOKEN_FILE" ] && tok="$(cat "$TOKEN_FILE")" && hdr="-H PRIVATE-TOKEN:$tok"
    if [ -n "$hdr" ]; then
        curl -s --max-time 15 $hdr -X DELETE "$URL/api/v4/projects/semi%2Fip%2Fdesign%2Fpush-lab" >/dev/null \
            && echo "[ok] push-lab 已删"
        uid=$(curl -s --max-time 15 $hdr "users?username=dev1" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d[0]['id'] if d else '')")
        [ -n "$uid" ] && curl -s --max-time 15 $hdr -X DELETE "$URL/api/v4/users/$uid?hard_delete=true" >/dev/null \
            && echo "[ok] dev1 已硬删"
    fi
    docker exec gitlab rm -f "$HOOK_DST" 2>/dev/null && echo "[ok] hook 已卸"
    python3 - "$PLATFORM_RB" <<'PY'
import re, sys
f = sys.argv[1]; s = open(f).read()
s = re.sub(r"\n## ── Server hooks（02_org_guard 加装）.*?\n}\n", "\n", s, flags=re.S)
open(f, "w").write(s)
print("[ok] gitlab.rb hooks 段已回滚（如原本由 02 追加）")
PY
    echo "[ok] 清理完成（如需让 hooks 配置彻底失效：docker exec gitlab gitlab-ctl reconfigure）"
}

main() {
    local target="${1:-up}"
    case "${target}" in
        up)     do_up ;;
        verify) do_verify ;;
        status) do_status ;;
        clean)  do_clean ;;
        *) echo "用法: $0 up | verify | status | clean" >&2; exit 1 ;;
    esac
}
main "$@"
