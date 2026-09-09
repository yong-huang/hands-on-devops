#!/usr/bin/env bash
# =============================================================================
# 02 · TF 模块化 — 主演示脚本
#
# 生命周期：lint → apply → observe → upgrade(改模块，两实例同步) → clean
# 用法：
#   ./tf_modules.sh            # 依次执行全部
#   ./tf_modules.sh lint       # 只跑 tflint 静态检查
#   ./tf_modules.sh upgrade    # 只演示"改一处、两实例同步更新"
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/tfrc.sh"
. "../../scripts/docker-env.sh"

TF="terraform -chdir=configs"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

wait_healthy() {
    local name="$1" i=0
    until [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null)" = "healthy" ]; do
        i=$((i+1)); [ $i -gt 30 ] && { echo "    [!] $name 30s 未 healthy"; return 1; }
        sleep 1
    done
}

do_lint() {
    step "lint" "tflint 静态检查（validate 之外的规则关）"
    command -v tflint >/dev/null || { echo "    [x] 缺 tflint：brew install tflint（或见 README 环境节）" >&2; exit 1; }
    # 在根模块跑 tflint；.tflint.hcl 用内置 ruleset，无网络依赖
    ( cd configs && tflint --recursive )
    note "[ok] tflint 零告警"
}

do_apply() {
    step "apply" "for_each 双实例：blue(28081) + green(28082)"
    $TF init -input=false
    $TF apply -auto-approve -input=false
    for k in blue green; do
        wait_healthy "tf02-$k-web" || true
        note "curl $k: $(curl -fsS http://localhost/$([ $k = blue ] && echo 28081 || echo 28082)/)"
    done
}

do_observe() {
    step "observe" "state 视角：一个模块、两个实例键"
    $TF state list | sed 's/^/        /'
    note "terraform graph 生成依赖图（DOT），本文档 §4 有节选"
    $TF graph | head -20 | sed 's/^/        /'
}

do_upgrade() {
    step "upgrade" "改模块公共逻辑：镜像 tag 升级 → 两实例同步重建"
    note "把 var.image 从 1.27 升到 1.29（-var 覆盖，不改代码演示）"
    $TF apply -auto-approve -input=false -var "image=nginx:1.29-alpine"
    for p in 28081 28082; do
        note "curl :$p → $(curl -fsS http://localhost:$p/)"
    done
    note "[ok] 一处模块定义，两处实例同步更新——这就是模块化的复利"
    $TF apply -auto-approve -input=false
    note "已回退到 1.27（保持实验可重复）"
}

do_clean() {
    step "clean" "destroy 全清 + 残留断言"
    $TF destroy -auto-approve -input=false
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep '^tf02' || true)
    if [ -z "$leftover" ] && ! docker network ls --format '{{.Name}}' | grep -q '^tf02' \
        && ! docker volume ls --format '{{.Name}}' | grep -q '^tf02'; then
        note "[ok] 零残留"
    else
        note "[!] 有残留：${leftover:-网络或卷}" >&2
        return 1
    fi
}

main() {
    local target="${1:-all}"
    case "${target}" in
        lint)    do_lint ;;
        apply)   do_lint; do_apply ;;
        observe) do_observe ;;
        upgrade) do_upgrade ;;
        clean)   do_clean ;;
        all)     do_lint; do_apply; do_observe; do_upgrade; do_clean ;;
        *) echo "可用: lint | apply | observe | upgrade | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
