#!/usr/bin/env bash
# =============================================================================
# 08 · Salt masterless — 主演示脚本
#
# masterless = 节点自己管理自己：salt-call --local 直读本地 state/pillar，
# 没有 master、没有 minion 配置、没有 ZooKeeper/消息总线。
# 运行环境：saltstack/salt 容器（amd64 经 Rosetta 模拟，教学用途性能足够）。
#
# ./salt_masterless.sh apply       起容器 + 首次 state.apply
# ./salt_masterless.sh idempotent  二次 apply（应全蓝 unchanged）
# ./salt_masterless.sh pillar      切 grain env=staging → pillar 数据变 → 配置自动更新
# ./salt_masterless.sh clean       销毁容器
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

C="lab08-salt"
SALT="docker exec $C salt-call --local --file-root=/srv/salt --pillar-root=/srv/pillar"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

wait_container() {
    local i=0
    until docker exec "$C" true >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 60 ] && { echo "    [!] 容器 60s 未就绪" >&2; exit 1; }
        sleep 1
    done
}

do_apply() {
    step "apply" "起 Salt 节点容器（amd64 模拟）并挂载 state/pillar"
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker run -d --name "$C" \
        -p 28096:8080 \
        -v "$(pwd)/saltfs/salt:/srv/salt" \
        -v "$(pwd)/saltfs/pillar:/srv/pillar" \
        saltstack/salt:latest sleep infinity >/dev/null
    wait_container

    note "grain 设定机器事实：env=dev"
    docker exec "$C" salt-call --local grains.setval env dev >/dev/null

    step "apply" "salt-call --local state.apply nginx（masterless 首次收敛）"
    docker exec "$C" salt-call --local state.apply nginx --state-output=terse | tail -6 | sed 's/^/        /'

    note "curl 验证渲染产物（pillar 数据 + grain 事实同框）"
    note "curl :28096/healthz → $(docker exec "$C" wget -qO- http://127.0.0.1:8080/healthz 2>/dev/null || wget -qO- http://127.0.0.1:8080/healthz)"
    note "curl :28096/ → $(docker exec "$C" wget -qO- http://127.0.0.1:8080/)"
}

do_idempotent() {
    step "idempotent" "二次 apply：声明式系统的'没有变化就什么都不做'"
    local out
    out=$(docker exec "$C" salt-call --local state.apply nginx --state-output=terse)
    echo "$out" | tail -2 | sed 's/^/        /'
    # salt 汇总行示例：        Summary: ... Succeeded: 3 (changed=0) ...
    if echo "$out" | grep -qE "changed=[1-9]"; then
        note "[x] 仍有变更：$(echo "$out" | grep -oE 'changed=[0-9]+' | head -1)" >&2; exit 1
    else
        note "[ok] 无任何状态变化（changed=0 或零变更汇总），幂等达成"
        echo "$out" | grep -E "Succeeded|Failed" | tail -2 | sed 's/^/        /'
    fi
}

do_pillar() {
    step "pillar" "grain env=dev → staging：pillar 数据变 → 配置自动重渲染"
    docker exec "$C" salt-call --local grains.setval env staging >/dev/null
    note "pillar 取值（按 grain 分叉后的数据）"
    docker exec "$C" salt-call --local pillar.items --state-output=terse 2>/dev/null | grep -E "greeting|app_env" | sed 's/^/        /'
    docker exec "$C" salt-call --local state.apply nginx --state-output=terse | grep -E "Summary|changed=" | tail -2 | sed 's/^/        /'
    note "curl :28096/ → $(docker exec "$C" wget -qO- http://127.0.0.1:8080/)"
    note "[ok] 配置内容随 grain/pillar 自动切换——数据驱动的环境差异"
    docker exec "$C" salt-call --local grains.setval env dev >/dev/null
    docker exec "$C" salt-call --local state.apply nginx >/dev/null 2>&1
}

do_clean() {
    step "clean" "销毁 Salt 节点容器"
    docker rm -f "$C" >/dev/null 2>&1 || true
    ! docker ps -a --format '{{.Names}}' | grep -q "^$C$" && note "[ok] 零残留" || { note "[!] 残留" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)      do_apply ;;
        idempotent) do_idempotent ;;
        pillar)     do_pillar ;;
        clean)      do_clean ;;
        all)        do_apply; do_idempotent; do_pillar; do_clean ;;
        *) echo "可用: apply | idempotent | pillar | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
