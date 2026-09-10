#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
do_up() {
    step "up" "启动 Prometheus + Grafana + Node Exporter"
    docker compose up -d --wait 2>&1 | tail -3 | sed 's/^/        /'
    note "Prometheus: http://localhost:9090"
    note "Grafana:     http://localhost:3001 (admin/admin)"
    note "验证: curl http://localhost:9090/api/v1/query?query=up"
    local r
    r=$(curl -s "http://localhost:9090/api/v1/query?query=up" | jq -r '.data.result[0].value[1]' 2>/dev/null)
    [ "$r" = "1" ] && note "[ok] Prometheus 查询正常" || note "[i] Prometheus 查询: $r"
}
do_down() {
    step "down" "销毁"
    docker compose down -v 2>&1 | tail -1 | sed 's/^/        /'
    note "[ok] 零残留"
}
case "${1:-up}" in
    up) do_up ;; down) do_down ;;
    *) echo "可用: up | down" >&2; exit 1 ;;
esac
