#!/usr/bin/env bash
# with_license.sh —— CI job 的许可证检出/归还包装器（模拟 FlexLM 客户端语义）
# 用法：LICENSE_SERVER=http://license-mock:9001 with_license.sh <holder名> <命令...>
# 行为：acquire（60s 内轮询，池空则等待）→ 执行命令 → trap 保证归还（命令失败也归还）
set -uo pipefail

SERVER="${LICENSE_SERVER:-http://license-mock:9001}"
HOLDER="${1:?用法: with_license.sh <holder名> <命令...>}"
shift

LEASE=""

release() {
    [ -n "$LEASE" ] && python3 "$(dirname "$0")/lic.py" release "$LEASE" >/dev/null 2>&1
    LEASE=""
}
trap release EXIT

# ── acquire：池空则等（60s 超时）──
t0=$(date +%s)
waited=0
while true; do
    if LEASE=$(python3 "$(dirname "$0")/lic.py" acquire "$HOLDER" 2>/dev/null); then
        break
    fi
    waited=$(( $(date +%s) - t0 ))
    echo "[with_license] lease wait ${waited}s（池满，排队中）"
    [ "$waited" -ge 60 ] && { echo "[with_license] acquire 超时"; exit 2; }
    sleep 5
done
echo "[with_license] lease acquired: ${LEASE:0:8}（holder=$HOLDER）"

# ── 执行被包装的命令 ──
"$@"
rc=$?

release
echo "[with_license] lease released (rc=$rc)"
exit $rc
