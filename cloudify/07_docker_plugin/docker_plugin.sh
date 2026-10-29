#!/usr/bin/env bash
# =============================================================================
# 07 · Docker 插件 — 官方 cloudify-docker-plugin 编排双容器 + 关系传值
#
# 用法：
#   ./docker_plugin.sh install     # init + install（api:28111 + web:28110，establish 抓 api 内网 IP）
#   ./docker_plugin.sh dataflow    # web 的 runtime property 含 api 的 bridge IP（跨容器数据流）
#   ./docker_plugin.sh outputs     # outputs.backend_endpoint 断言
#   ./docker_plugin.sh uninstall   # 零容器残留
#   ./docker_plugin.sh             # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=dock
WEB_PORT=28110
API_PORT=28111

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

cleanup_containers() {
    docker rm -f cfy07-web cfy07-api >/dev/null 2>&1 || true
    return 0
}

do_install() {
    step install "init + install：官方 docker 插件起 api + web 双容器"
    cleanup_containers
    reset_workdir
    cfy_run init init -b "$DEP" bp.yaml
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    must_contain .logs/install.log "create_container" "插件任务 create_container 执行"
    [ "$(docker ps -q --filter name=cfy07- | wc -l | tr -d ' ')" = "2" ] || fail "cfy07-* 容器应 2 个"
    ok "docker ps：2 个命名容器在跑"
    local code_w code_a
    code_w=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://localhost:$WEB_PORT/")
    code_a=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://localhost:$API_PORT/")
    [ "$code_w" = "200" ] && [ "$code_a" = "200" ] || fail "curl web=$code_w api=$code_a 应均 200"
    ok "curl 宿主侧 web/api 均 200（:$WEB_PORT :${API_PORT}）"
}

do_dataflow() {
    step dataflow "关系传值：establish 把 api 的 bridge IP 写进 web 的 runtime properties"
    local endpoint
    endpoint=$(inst_attr "$DEP" backend_endpoint | head -1)
    echo "        backend_endpoint = $endpoint"
    echo "$endpoint" | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:80$" \
        || fail "backend_endpoint 应为 bridge IP:80，实为 $endpoint"
    ok "backend_endpoint 是 docker 内网地址（来自 docker SDK inspect）"
    local cid
    cid=$(inst_attr "$DEP" backend_container_id | head -1)
    [ -n "$cid" ] || fail "backend_container_id 未写入"
    ok "backend_container_id = $cid"
    must_contain .logs/install.log "establish: web -> api in-docker" "establish 日志证据"
}

do_outputs() {
    step outputs "outputs 读回跨容器数据流"
    cfy_run outputs deployments outputs -b "$DEP"
    must_contain .logs/outputs.log '"backend_endpoint": "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:80"' \
        "outputs.backend_endpoint = bridge IP:80"
}

do_uninstall() {
    step uninstall "uninstall → remove_container 零残留"
    cfy_run uninstall executions start uninstall -b "$DEP"
    must_contain .logs/uninstall.log "'uninstall' workflow execution succeeded" "uninstall 工作流成功"
    local residue
    residue=$(docker ps -aq --filter name=cfy07- | wc -l | tr -d ' ')
    [ "$residue" = "0" ] || fail "cfy07-* 容器残留 $residue 个"
    ok "docker ps -a 零残留"
}

case "${1:-all}" in
    install)   do_install ;;
    dataflow)  do_dataflow ;;
    outputs)   do_outputs ;;
    uninstall) do_uninstall ;;
    all)
        do_install
        do_dataflow
        do_outputs
        do_uninstall
        echo; echo "✅ 07 全部通过"
        ;;
    *) echo "用法: $0 [install|dataflow|outputs|uninstall|all]"; exit 1 ;;
esac
