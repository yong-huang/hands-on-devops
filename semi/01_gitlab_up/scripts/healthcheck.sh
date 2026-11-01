#!/usr/bin/env bash
# 轮询 GitLab 就绪：/users/sign_in 返回 200（首次启动实测 4-6 分钟：reconfigure + DB 迁移）。
# 注：新版 GitLab CE 的 /-/readiness、/-/health 端点默认下线（实测 404），
#     登录页 200 是最直接的「平台可用」信号，配合 verify 里的 gitlab-ctl status 双确认。
set -euo pipefail
cd "$(dirname "$0")/.."

URL="${GITLAB_URL:-http://localhost:28200}"
TIMEOUT="${GITLAB_BOOT_TIMEOUT:-900}"   # 默认给 15 分钟：首启最慢的一次要留足
POLL_INTERVAL=10

step() { echo "=====> [$1] $2"; }

step wait "轮询 $URL/users/sign_in（最长 ${TIMEOUT}s，每 ${POLL_INTERVAL}s 一次）"
start=$(date +%s)
deadline=$(( start + TIMEOUT ))
while true; do
    # curl -sf：非 2xx（启动中 rails 未起或迁移中会 5xx/502）或连不上都算未就绪
    if curl -sf --max-time 10 "$URL/users/sign_in" -o /dev/null 2>/dev/null; then
        echo "[ok] GitLab 就绪（耗时 $(( $(date +%s) - start ))s）"
        exit 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "[fail] ${TIMEOUT}s 内未就绪，最后状态："
        docker ps --filter name=gitlab --format 'table {{.Names}}\t{{.Status}}' || true
        docker logs gitlab --tail 30 2>&1 || true
        exit 1
    fi
    printf '.'; sleep "$POLL_INTERVAL"
done
