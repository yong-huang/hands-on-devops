#!/usr/bin/env bash
# =============================================================================
# 04 · 多环境矩阵 — 主演示脚本
#
# 两种组织法各跑一遍 dev + staging：
#   ./tf_environments.sh workspace   # 方式一：workspace 法（切换 + apply）
#   ./tf_environments.sh dirs        # 方式二：目录法（两个目录各自 apply）
#   ./tf_environments.sh compare     # 两法参数对照表
#   ./tf_environments.sh clean       # 全部销毁
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/tfrc.sh"
. "../../scripts/docker-env.sh"

WS="terraform -chdir=configs-workspace"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

wait_healthy() {
    local name="$1" i=0
    until [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null)" = "healthy" ]; do
        i=$((i+1)); [ $i -gt 30 ] && { echo "    [!] $name 30s 未 healthy"; return 1; }
        sleep 1
    done
}

do_workspace() {
    step "workspace" "方式一：一份配置，两个 workspace 各自 apply"
    $WS init -input=false
    $WS workspace select dev 2>/dev/null || $WS workspace new dev
    note "workspace=dev：镜像 1.27 / 副本 1 / 端口 28090"
    $WS apply -auto-approve -input=false
    wait_healthy tf04-ws-dev-1 || true
    note "curl :28090 → $(curl -fsS -o /dev/null -w '%{http_code}' http://localhost:28090/)"

    $WS workspace select staging 2>/dev/null || $WS workspace new staging
    note "workspace=staging：镜像 1.29 / 副本 2 / 端口 28091+28092"
    $WS apply -auto-approve -input=false
    wait_healthy tf04-ws-staging-1 || true
    wait_healthy tf04-ws-staging-2 || true
    note "curl :28091 → $(curl -fsS -o /dev/null -w '%{http_code}' http://localhost:28091/)"
    note "curl :28092 → $(curl -fsS -o /dev/null -w '%{http_code}' http://localhost:28092/)"
    note "每个 workspace 独立 state：workspace list"
    $WS workspace list | sed 's/^/        /'
}

do_dirs() {
    step "dirs" "方式二：envs/dev 与 envs/staging 各自 apply"
    ( cd envs/dev && terraform init -input=false >/dev/null && terraform apply -auto-approve -input=false )
    wait_healthy tf04-dir-dev-1 || true
    note "dev :28093 → $(curl -fsS -o /dev/null -w '%{http_code}' http://localhost:28093/)"

    ( cd envs/staging && terraform init -input=false >/dev/null && terraform apply -auto-approve -input=false )
    wait_healthy tf04-dir-staging-1 || true
    wait_healthy tf04-dir-staging-2 || true
    note "staging :28094 → $(curl -fsS -o /dev/null -w '%{http_code}' http://localhost:28094/)"
    note "staging :28095 → $(curl -fsS -o /dev/null -w '%{http_code}' http://localhost:28095/)"
}

do_compare() {
    step "compare" "同一套基础设施，两种组织法"
    cat <<'TBL'
        ┌──────────┬────────────────────────┬──────────────────────────┐
        │ 维度      │ workspace 法            │ 目录法                    │
        ├──────────┼────────────────────────┼──────────────────────────┤
        │ 环境参数   │ 代码里查表(locals map)  │ 各目录写死/-var-file      │
        │ state     │ 同 backend 按 ws 隔离   │ 目录天然隔离              │
        │ 切换方式   │ workspace select(易切错)│ cd 目录（想错都难）        │
        │ 漂移爆炸   │ 一份配置全环境连坐       │ 环境间有"物理墙"           │
        │ 代码重复   │ 零重复                  │ 根模块少量重复             │
        │ 适用       │ 环境少且同构、个人/小队  │ 环境少而边界严、生产主流   │
        └──────────┴────────────────────────┴──────────────────────────┘
TBL
    note "本机真实端口分配：ws-dev 28090 · ws-staging 28091/2 · dir-dev 28093 · dir-staging 28094/5"
}

do_clean() {
    step "clean" "销毁两法全部环境 + 删除 workspace"
    ( cd envs/dev && terraform destroy -auto-approve -input=false ) || true
    ( cd envs/staging && terraform destroy -auto-approve -input=false ) || true
    $WS workspace select dev 2>/dev/null || true
    $WS destroy -auto-approve -input=false || true
    $WS workspace select staging 2>/dev/null || $WS workspace new staging >/dev/null 2>&1 || true
    $WS destroy -auto-approve -input=false || true
    $WS workspace select default >/dev/null 2>&1 || true
    $WS workspace delete dev >/dev/null 2>&1 || true
    $WS workspace delete staging >/dev/null 2>&1 || true
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep '^tf04' || true)
    [ -z "$leftover" ] && note "[ok] 零残留" || { note "[!] 残留：$leftover" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        workspace) do_workspace ;;
        dirs)      do_dirs ;;
        compare)   do_compare ;;
        clean)     do_clean ;;
        all)       do_workspace; do_dirs; do_compare; do_clean ;;
        *) echo "可用: workspace | dirs | compare | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
