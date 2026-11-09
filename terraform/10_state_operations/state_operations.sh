#!/usr/bin/env bash
# =============================================================================
# 10 · state 操作全家桶 — 主演示脚本
#
# 一台手工创建的"存量"容器走完身份的四段旅程（对照图见 README）：
#   [纳管]   import block + 配置生成：plan 出 "1 to import"，apply 后 plan
#            直接 No changes（生成配置 = 账本实况，天然收敛）
#   [改名A]  moved block（HCL 声明式）：地址 legacy→web，plan 0 destroy——
#            只是账本换了页签，引擎里的容器纹丝不动
#   [改名B]  terraform state mv（命令行命令式）：镜像地址同戏重演——
#            两种工具殊途同归，plan 都收敛
#   [摘除]   state rm：账本抹掉记录，容器还活着 → plan 竟要"重新创建"它
#            （名字冲突危险面）——摘除 ≠ 删除，这是最容易被误解的一点
#
# ./state_operations.sh up      手工造一台"存量"容器（Terraform 出场前它就在）
# ./state_operations.sh import  import block 纳管 + 配置生成 + 收敛断言
# ./state_operations.sh moved   moved block 改名（0 destroy 断言）
# ./state_operations.sh statemv state mv 改名对照（镜像地址）
# ./state_operations.sh rm      state rm 摘除 + 危险面断言
# ./state_operations.sh verify  终态断言（账实一致 + backup 链在）
# ./state_operations.sh clean   销毁一切，零残留
# ./state_operations.sh all     上面七步一条龙
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# provider 走仓库内置 filesystem mirror（scripts/tfrc.sh）——离线秒装
. "../../scripts/tfrc.sh"

WORK="tmp/work"
PASS=0 FAIL=0

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

assert() {
    local desc="$1" rc="$2"
    if [ "$rc" -eq 0 ]; then
        PASS=$((PASS+1)); note "[ok]   $desc"
    else
        FAIL=$((FAIL+1)); note "[FAIL] $desc"
    fi
}

# 稳定取 plan/apply 的 rc：输出进变量，失败不触发 set -e
tfrun() {
    local rc=0 out
    out=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform "$@" ) 2>&1 ) || rc=$?
    echo "$out" | tail -4 | sed 's/^/        /'
    return "$rc"
}

do_up() {
    step "up" "手工造一台'存量'容器（Terraform 出场前它就在——这就是要纳管的存量）"
    docker rm -f tf10-legacy tf10-temp >/dev/null 2>&1 || true
    docker run -d --name tf10-legacy alpine:3 sleep infinity >/dev/null
    sleep 1
    mkdir -p tmp
    docker inspect tf10-legacy --format '{{.Id}}' > tmp/legacy.id   # importer 只认完整 64 位 ID
    local aok1=1
        docker ps --format '{{.Names}} {{.Status}}' | grep -q "^tf10-legacy" && aok1=0 || true
assert "存量容器 tf10-legacy 运行中（此刻 Terraform 不认识它）" ${aok1}
}

do_import() {
    step "import" "纳管：import block + 配置生成（TF 1.5+ 的现代路线）"
    mkdir -p "$WORK"
    cp configs/versions.tf configs/main.tf "$WORK/"
    local legacy_id
    legacy_id=$(cat tmp/legacy.id 2>/dev/null || docker inspect tf10-legacy --format '{{.Id}}')
    cat > "$WORK/import.tf" <<EOF
import {
  to = docker_container.legacy
  id = "$legacy_id"
}
EOF
    ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform init -input=false -no-color >/dev/null 2>&1 ) \
        || { echo "    [!] terraform init 失败" >&2; exit 1; }
    # 配置生成：让 TF 照账本实况写出资源体（config == state，后续 plan 天然收敛）
    local prc=0 pout
    pout=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform plan -input=false -no-color \
        -generate-config-out=generated.tf ) 2>&1 ) || prc=$?
    echo "$pout" | grep -E "1 to import|generated" | sed 's/^/        /' || true
    local iok=1
    echo "$pout" | grep -q "1 to import" && iok=0 || true
    assert "plan 识别到 1 个待纳管资源（1 to import）" "$iok"
    [ -f "$WORK/generated.tf" ] && iok=0 || iok=1
    assert "配置生成落地（generated.tf 已写出资源体）" "$iok"

    ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color \
        >/dev/null 2>&1 ) || true   # generated.tf 已由上一步 plan 写出；apply 不认该旗标
    rm -f "$WORK/import.tf"   # 纳管完成的 import block 必须移除，否则下次 plan 报错
    note "apply 完成纳管，import.tf 已按规矩移除"

    local vrc=1
    tfrun plan -input=false -no-color | grep -q "No changes" && vrc=0 || true
    assert "纳管后 plan → No changes（生成配置与账本天然一致）" "$vrc"
    local aok2=1
        ( cd "$WORK" && terraform state list ) | grep -q "docker_container.legacy" && aok2=0 || true
assert "state list 出现 docker_container.legacy" ${aok2}
}

do_moved() {
    step "moved" "改名A：moved block（HCL 声明式）——地址 legacy→web"
    # 资源体在配置生成写出的 generated.tf 里；改名只动资源地址（label），
    # 容器名 tf10-legacy 与引擎里的实体不动
    # HCL 资源标签写作 "docker_container" "legacy"（引号空格），别用点号匹配——
    # 点号形式只出现在 moved 块里，误替换会造出 from=web to=web 的自相矛盾
    sed -i '' 's/"docker_container" "legacy"/"docker_container" "web"/g' "$WORK/generated.tf"
    cat >> "$WORK/generated.tf" <<'EOF'

moved {
  from = docker_container.legacy
  to   = docker_container.web
}
EOF
    local mrc=0 mout
    mout=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform plan -input=false -no-color ) 2>&1 ) || mrc=$?
    echo "$mout" | grep -E "Plan:" | sed 's/^/        /' || true
    local dok=1
    echo "$mout" | grep -q "0 to destroy" && dok=0 || true
    assert "moved 后 plan 0 to destroy（只挪账本，不动引擎）" "$dok"
    ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color >/dev/null 2>&1 ) || true
    local aok3=1
        ( cd "$WORK" && terraform state list ) | grep -q "docker_container.web" && aok3=0 || true
assert "state list 出现 docker_container.web（旧地址已消失）" ${aok3}
}

do_statemv() {
    step "statemv" "改名B：terraform state mv（命令行命令式）——镜像地址同戏重演"
    # 与 moved 等价的命令式做法：先改配置地址，再 mv 账本记录——两条路殊途同归
    sed -i '' 's/"docker_image" "demo"/"docker_image" "web_image"/g' "$WORK/main.tf"
    ( cd "$WORK" && terraform state mv docker_image.demo docker_image.web_image >/dev/null 2>&1 ) || true
    local vrc=1
    tfrun plan -input=false -no-color | grep -q "No changes" && vrc=0 || true
    assert "state mv + 配置同步改名后 plan → No changes（与 moved 殊途同归）" "$vrc"
    local aok4=1
        ( cd "$WORK" && terraform state list ) | grep -q "docker_image.web_image" && aok4=0 || true
assert "state list 出现 docker_image.web_image" ${aok4}
}

do_rm() {
    step "rm" "摘除：state rm——抹账本，不动引擎（最易误解的操作）"
    cp configs/temp.tf "$WORK/"
    ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color \
        -target=docker_container.temp >/dev/null 2>&1 ) || true
    note "TF 已创建 tf10-temp（-target 单资源创建）"
    ( cd "$WORK" && terraform state rm docker_container.temp >/dev/null 2>&1 ) || true
    local s1=1 s2=1
    ( cd "$WORK" && terraform state list ) | grep -q "docker_container.temp" || s1=0
    assert "state rm 后 state list 无 docker_container.temp（账本已抹）" "$s1"
    docker ps --format '{{.Names}}' | grep -q "^tf10-temp$" && s2=0
    assert "容器 tf10-temp 还活着（摘除 ≠ 删除！）" "$s2"
    local prc=0 pout
    pout=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform plan -input=false -no-color ) 2>&1 ) || prc=$?
    local pok=1
    echo "$pout" | grep -q "1 to add" && pok=0 || true
    assert "plan 竟要'重新创建'它（1 to add）——对不认识的资源这就是名字冲突危险面" "$pok"

    note "收场：删配置声明 + 删容器，账实重新对齐"
    rm -f "$WORK/temp.tf"
    docker rm -f tf10-temp >/dev/null
    local vrc=1
    tfrun plan -input=false -no-color | grep -q "No changes" && vrc=0 || true
    assert "收场后 plan → No changes（账实重新对齐）" "$vrc"

    echo
    note "断言汇总：PASS=${PASS} FAIL=${FAIL}"
    [ "$FAIL" -eq 0 ] || exit 1
}

do_verify() {
    step "verify" "终态断言：账实一致 + backup 链在"
    local prc=1
    tfrun plan -input=false -no-color | grep -q "No changes" && prc=0 || true
    assert "terraform plan → No changes" "$prc"
    local s=0
    ( cd "$WORK" && terraform state list ) | grep -q "docker_container.web" || s=1
    ( cd "$WORK" && terraform state list ) | grep -q "docker_image.web_image" || s=1
    assert "state 同时持有改名后的容器与镜像地址" "$s"
    local aok5=1
        docker ps --format '{{.Names}}' | grep -q "^tf10-legacy$" && aok5=0 || true
assert "引擎侧 tf10-legacy 仍是当初那台（改的只是账本）" ${aok5}
    [ -f "$WORK/terraform.tfstate.backup" ]
    assert "本地 state 的 backup 链在（每次 state 变动自动留底）" $?

    echo
    note "断言汇总：PASS=${PASS} FAIL=${FAIL}"
    [ "$FAIL" -eq 0 ] || exit 1
}

do_clean() {
    step "clean" "销毁一切（destroy 会真删被纳管的容器——纳管即接管）"
    if [ -d "$WORK" ]; then
        ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform destroy -auto-approve -input=false -no-color \
            >/dev/null 2>&1 ) || true
    fi
    docker rm -f tf10-legacy tf10-temp >/dev/null 2>&1 || true
    rm -rf tmp
    local lrc=0
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE "tf10" && lrc=1 || true
    assert "零残留（无 tf10 容器，工作区已删）" "$lrc"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)      do_up ;;
        import)  do_import ;;
        moved)   do_moved ;;
        statemv) do_statemv ;;
        rm)      do_rm ;;
        verify)  do_verify ;;
        clean)   do_clean ;;
        all)     do_up; do_import; do_moved; do_statemv; do_rm; do_verify; do_clean ;;
        *) echo "可用: up | import | moved | statemv | rm | verify | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
