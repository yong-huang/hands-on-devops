#!/usr/bin/env bash
# =============================================================================
# 10 · 金丝雀发布与指标门禁 — 主演示脚本
#
# 完整生命周期：up → promote → abort → clean
# 用法：
#   ./canary.sh up         # 起双槽 + edge，断言基线 100% v1
#   ./canary.sh promote    # 三档晋级 90/10 → 50/50 → 100，每档千次请求断言分布
#   ./canary.sh abort      # 注入 v2 5xx → 错误率门禁超阈值 → 自动中止回 v1
#   ./canary.sh clean      # 销毁环境，配置复位
#   ./canary.sh            # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

EDGE_PORT=29080
BLUE_PORT=29081
GREEN_PORT=29082
UPSTREAM=compose/conf/edge/upstream
GREEN_CONF=compose/conf/green_active.conf
HEALTHY_CONF=compose/conf/slot_v2.conf
FAULT_CONF=compose/conf/slot_v2_bad.conf
LOGS=.logs
THRESHOLD=10        # 错误率门禁阈值（百分比）
PROBE_N=1000        # 每档分布取样数
GATE_N=300          # 门禁错误率取样数

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

point_at()   { cat "${UPSTREAM}/$1.conf" > "${UPSTREAM}/active.conf"; }
reload_edge()  { docker compose -f compose/docker-compose.yml exec -T edge nginx -s reload; }
reload_green() { docker compose -f compose/docker-compose.yml exec -T green nginx -s reload; }

api() { curl -s --max-time 2 "http://127.0.0.1:${EDGE_PORT}/api" 2>/dev/null || true; }

# 并发打 $1 个请求到 edge /api，输出 "v1 v2 empty" 计数
fire() {
    local n="$1" out
    out="$(seq 1 "${n}" | xargs -P 10 -I{} curl -s --max-time 2 \
        "http://127.0.0.1:${EDGE_PORT}/api" 2>/dev/null | sort | uniq -c || true)"
    local v1 v2
    v1="$(awk '$2=="v1-ok"{print $1}' <<< "${out}")"; v1="${v1:-0}"
    v2="$(awk '$2=="v2-ok"{print $1}' <<< "${out}")"; v2="${v2:-0}"
    echo "${v1} ${v2} $((n - v1 - v2))"
}

wait_healthy() {
    local svc="$1" id st="" i
    id="$(docker compose -f compose/docker-compose.yml ps -q "${svc}")"
    for i in $(seq 1 30); do
        st="$(docker inspect -f '{{.State.Health.Status}}' "${id}" 2>/dev/null || true)"
        [ "${st}" = "healthy" ] && { note "[ok] ${svc} healthy"; return 0; }
        sleep 1
    done
    echo "        [!] ${svc} 未 healthy" >&2
    return 1
}

# 分布断言：$1=期望 green 百分比 $2=档位名——1000 请求统计实际占比，偏差 < 10pp
dist_check() {
    local want="$1" label="$2" read v1 v2 empty share dev
    read -r v1 v2 empty <<< "$(fire "${PROBE_N}")"
    [ "${empty}" = "0" ] || { echo "        [!] ${label} 有 ${empty} 个请求失败" >&2; exit 1; }
    read -r share dev <<< "$(python3 -c "print($v2*100/${PROBE_N}, abs($v2*100/${PROBE_N}-${want}))")"
    python3 -c "import sys; sys.exit(0 if ${dev} < 10 else 1)" \
        || { echo "        [!] ${label} 分布偏差 ${dev}pp ≥ 10pp（实际 green ${share}%，配置 ${want}%）" >&2; exit 1; }
    note "[ok] ${label}：${PROBE_N} 请求 → v1 × ${v1} / v2 × ${v2}（green ${share}% vs 配置 ${want}%，偏差 ${dev}pp < 10pp）"
}

do_up() {
    step "up" "起双槽 + edge，断言基线 100% v1"
    mkdir -p "${LOGS}"
    cat "${HEALTHY_CONF}" > "${GREEN_CONF}"
    point_at v1only
    docker compose -f compose/docker-compose.yml up -d
    wait_healthy blue
    wait_healthy green
    reload_edge   # compose up 不重建未变化的容器——内存配置须与 active.conf 对齐
    sleep 0.3
    local read v1 v2 empty
    read -r v1 v2 empty <<< "$(fire 200)"
    [ "${v2}" = "0" ] && [ "${empty}" = "0" ] \
        || { echo "        [!] 基线应为 100% v1，实测 v1×${v1} v2×${v2} 空×${empty}" >&2; exit 1; }
    note "[ok] 基线 200 请求全量 v1（v2 × 0）"
}

do_promote() {
    step "promote" "三档晋级 90/10 → 50/50 → 100，每档 ${PROBE_N} 请求断言分布"
    point_at w9010; reload_edge; sleep 0.3
    dist_check 10 "第一档 90/10"
    point_at w5050; reload_edge; sleep 0.3
    dist_check 50 "第二档 50/50"
    point_at w100g; reload_edge; sleep 0.3
    dist_check 100 "第三档 100% green"
    note "[ok] 三档全部达标——若门禁持续绿，全量晋级完成"
}

do_abort() {
    step "abort" "注入 v2 5xx → 错误率门禁超阈值 → 自动中止晋级回 v1"
    # 回到晋级中段 50/50，模拟"放量中途发现故障"
    point_at w5050; reload_edge
    cat "${FAULT_CONF}" > "${GREEN_CONF}"; reload_green; sleep 0.3
    note "故障已注入：green /api → 503（/version 仍 200——健康检查看不见业务路径的故障）"
    # 指标门禁：度量 edge /api 真实错误率
    local codes err=0
    codes="$(seq 1 "${GATE_N}" | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
        "http://127.0.0.1:${EDGE_PORT}/api" 2>/dev/null | sort | uniq -c || true)"
    err="$(awk '$2!=200{e+=$1} END{print e+0}' <<< "${codes}")"
    read -r rate <<< "$(python3 -c "print($err*100/${GATE_N})")"
    python3 -c "import sys; sys.exit(0 if ${rate} > ${THRESHOLD} else 1)" \
        || { echo "        [!] 错误率 ${rate}% 未超阈值 ${THRESHOLD}%——门禁不触发（实验应触发）" >&2; exit 1; }
    note "[ok] 门禁采样 ${GATE_N} 请求：非 200 × ${err}（错误率 ${rate}% > 阈值 ${THRESHOLD}%）→ 自动中止晋级"
    # 止血：upstream 摘除 green，流量 100% 回 v1
    point_at v1only; reload_edge; sleep 0.3
    local read v1 v2 empty
    read -r v1 v2 empty <<< "$(fire "${PROBE_N}")"
    [ "${v1}" = "${PROBE_N}" ] && [ "${v2}" = "0" ] && [ "${empty}" = "0" ] \
        || { echo "        [!] 止血后应 100% v1，实测 v1×${v1} v2×${v2} 空×${empty}" >&2; exit 1; }
    note "[ok] 止血后 ${PROBE_N} 请求全量 v1（v2 × 0）——中止即秒回稳定版"
    # 回滚 ≠ 修复：green 槽自身仍带着故障
    local green_api green_code
    green_api="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
        "http://127.0.0.1:${GREEN_PORT}/api" || true)"
    [ "${green_api}" = "503" ] \
        || { echo "        [!] green 直连期望仍 503，实际 ${green_api}" >&2; exit 1; }
    note "[ok] green 直连仍 503——回滚是切走流量，不是修好故障（修槽是另一件事）"
}

do_clean() {
    step "clean" "销毁环境，配置复位"
    docker compose -f compose/docker-compose.yml down 2>/dev/null || true
    cat "${HEALTHY_CONF}" > "${GREEN_CONF}"
    point_at v1only
    rm -rf "${LOGS}"
    note "[ok] 容器已清；green_active/active.conf 已复位；日志已清"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)      do_up ;;
        promote) do_promote ;;
        abort)   do_abort ;;
        clean)   do_clean ;;
        all)     do_up; do_promote; do_abort; do_clean ;;
        *) echo "可用: up | promote | abort | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
