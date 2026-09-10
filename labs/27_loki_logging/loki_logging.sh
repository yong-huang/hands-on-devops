#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
do_up() {
    step "up" "启动 Loki"
    docker compose up -d --wait 2>&1 | tail -2 | sed 's/^/        /'
    note "Loki: http://localhost:3100"
    local r
    r=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3100/ready)
    [ "$r" = "200" ] && note "[ok] Loki 就绪" || note "[i] Loki: $r"
}
do_down() {
    step "down" "销毁"
    docker compose down -v 2>&1 | tail -1
    note "[ok] 零残留"
}
case "${1:-up}" in
    up) do_up ;; down) do_down ;;
    *) echo "可用: up | down" >&2; exit 1 ;;
esac
