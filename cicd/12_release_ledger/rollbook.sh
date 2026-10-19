#!/usr/bin/env bash
# =============================================================================
# 12 · 版本账本与一键回滚 — 主演示脚本
#
# 完整生命周期：up → deploy v2 → deploy v3 → rollback v1 → recon → clean
# 用法：
#   ./rollbook.sh up                # 起网络 + edge + 部署 v1，账本立账
#   ./rollbook.sh deploy <version>  # 部署版本到空闲槽：体检 → 拨指针 → 记账
#   ./rollbook.sh rollback <version># 一键回滚：账本找版本 → 拉起 → 回拨 → 记账
#   ./rollbook.sh recon             # 三方对账：账本指针 ↔ 容器镜像/标签 ↔ 线上版本
#   ./rollbook.sh clean             # 销毁环境（账本随 .logs 清除）
#   ./rollbook.sh                   # 依次执行以上全部，并断言部署+回滚全程 < 60s
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

NET=cicd12
EDGE_NAME=edge12
EDGE_PORT=29080
BLUE_PORT=29081
GREEN_PORT=29082
UPSTREAM=conf/edge/upstream
LOGS=.logs
LEDGER="${LOGS}/ledger.json"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
now_iso() { python3 -c 'from datetime import datetime, timezone, timedelta; print(datetime.now(timezone(timedelta(hours=8))).isoformat(timespec="seconds"))'; }
now_s() { python3 -c 'import time; print(time.time())'; }

image_for() {
    case "$1" in
        v1) echo "nginx:1.27-alpine" ;;
        v2) echo "nginx:1.25-alpine" ;;
        v3) echo "nginx:1.29-alpine" ;;
        *) echo "" ;;
    esac
}
port_for() { case "$1" in blue) echo "${BLUE_PORT}";; green) echo "${GREEN_PORT}";; esac; }

# ---- 账本：JSON 追加只写，python3 落笔 --------------------------------------
ledger_add() {  # $1=action $2=version $3=slot $4=reason [$5=from]
    local action="$1" version="$2" slot="$3" reason="$4" from="${5:-}"
    python3 - "${LEDGER}" "${action}" "${version}" "${slot}" "${reason}" "${from}" "$(image_for "${version}")" << 'PY'
import json, sys
path, action, version, slot, reason, frm, image = sys.argv[1:8]
try:
    book = json.load(open(path))
except Exception:
    book = []
rec = {
    "seq": len(book) + 1,
    "ts": __import__("datetime").datetime.now(__import__("datetime").timezone(
        __import__("datetime").timedelta(hours=8))).isoformat(timespec="seconds"),
    "action": action,
    "version": version,
    "slot": slot,
    "image": image,
    "operator": "rollbook.sh",
    "reason": reason,
}
if frm:
    rec["from"] = frm
book.append(rec)
json.dump(book, open(path, "w"), ensure_ascii=False, indent=2)
print(f"{rec['seq']} {action} {version} slot={slot}")
PY
}

ledger_last() {  # 输出最后一条记录的 "action version slot image"
    python3 - "${LEDGER}" << 'PY'
import json, sys
book = json.load(open(sys.argv[1]))
r = book[-1]
print(r["action"], r["version"], r["slot"], r["image"])
PY
}

ledger_current() {  # 账本口径的"线上版本"：最后一条记录的 version
    python3 - "${LEDGER}" << 'PY'
import json, sys
print(json.load(open(sys.argv[1]))[-1]["version"])
PY
}

# ---- 槽位与指针 --------------------------------------------------------------
active_slot() { grep -oE 'server [a-z-]+:80' "${UPSTREAM}/active.conf" | awk '{print $2}' | sed 's/:80$//; s/^slot-//'; }
point_at() { cat "${UPSTREAM}/$1.conf" > "${UPSTREAM}/active.conf"; }
reload_edge() {
    # nginx 在配置加载时解析 upstream 主机名——若 edge 启动早于槽容器会
    # emerg 退出；这里兜底：没在跑就重新 start（此时槽已就绪，可解析）
    local st
    st="$(docker inspect -f '{{.State.Running}}' "${EDGE_NAME}" 2>/dev/null || echo false)"
    [ "${st}" = "true" ] || docker start "${EDGE_NAME}" >/dev/null
    docker exec "${EDGE_NAME}" nginx -s reload
}

edge_version() { curl -s --max-time 2 "http://127.0.0.1:${EDGE_PORT}/version" 2>/dev/null || true; }
expect_edge() {
    local want="$1" got="" i
    for i in $(seq 1 50); do
        got="$(edge_version | tr -d '\n')"
        [ "${got}" = "${want}" ] && { note "[ok] edge /version = ${got}"; return 0; }
        sleep 0.2
    done
    echo "        [!] edge /version 期望 ${want}，实际 '${got}'" >&2
    return 1
}

# 槽位体检：不 healthy 不拨指针
gate_slot() {
    local slot="$1" want="$2" port got i
    port="$(port_for "${slot}")"
    for i in $(seq 1 30); do
        got="$(curl -s --max-time 2 "http://127.0.0.1:${port}/version" 2>/dev/null | tr -d '\n' || true)"
        [ "${got}" = "${want}" ] && { note "[ok] 体检通过：${slot} /version = ${got}"; return 0; }
        sleep 0.5
    done
    echo "        [!] ${slot} 体检不过（期望 ${want}，实际 '${got}'）——拒绝拨指针" >&2
    return 1
}

run_slot() {  # $1=slot $2=version：拉起槽容器（同槽重部署 = 先删后起）
    local slot="$1" ver="$2" port img conf
    port="$(port_for "${slot}")"
    img="$(image_for "${ver}")"
    conf="conf/site_${ver}.conf"
    docker rm -f "slot-${slot}" >/dev/null 2>&1 || true
    docker run -d --name "slot-${slot}" --network "${NET}" -p "${port}:80" \
        --label "version=${ver}" --label "slot=${slot}" \
        -v "$PWD/${conf}:/etc/nginx/conf.d/default.conf:ro" "${img}" >/dev/null
}

do_up() {
    step "up" "起网络 + 槽 + edge + 部署 v1，账本立账"
    mkdir -p "${LOGS}"
    echo '[]' > "${LEDGER}"
    docker network create "${NET}" >/dev/null 2>&1 || true
    # 槽先于 edge：nginx 加载配置时要能解析 upstream 主机名
    point_at blue
    run_slot blue v1
    docker rm -f "${EDGE_NAME}" >/dev/null 2>&1 || true
    docker run -d --name "${EDGE_NAME}" --network "${NET}" -p "${EDGE_PORT}:80" \
        -v "$PWD/conf/edge/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$PWD/${UPSTREAM}:/etc/nginx/upstream:ro" nginx:1.27-alpine >/dev/null
    gate_slot blue v1
    reload_edge
    sleep 0.3
    expect_edge v1
    ledger_add deploy v1 blue "首次部署（账本立账）" >/dev/null
    note "[ok] 账本第 1 笔：deploy v1 @ blue"
}

do_deploy() {
    local ver="$1" cur idle
    step "deploy" "部署 ${ver} 到空闲槽：体检 → 拨指针 → 记账"
    cur="$(active_slot)"
    idle=blue; [ "${cur}" = "blue" ] && idle=green
    run_slot "${idle}" "${ver}"
    gate_slot "${idle}" "${ver}"
    point_at "${idle}"
    reload_edge
    sleep 0.3
    expect_edge "${ver}"
    ledger_add deploy "${ver}" "${idle}" "常规发布" >/dev/null
    note "[ok] 账本追加：deploy ${ver} @ ${idle}"
}

do_rollback() {
    local target="$1" cur
    step "rollback" "一键回滚到 ${target}：账本指路 → 拉起 → 回拨 → 记账"
    [ -n "$(image_for "${target}")" ] || { echo "        [!] 未知版本 ${target}" >&2; exit 1; }
    cur="$(ledger_current)"
    [ "${cur}" != "${target}" ] || { echo "        [!] 当前已是 ${target}，无需回滚" >&2; exit 1; }
    # 回滚走与部署完全相同的通道：体检过才拨指针
    local idle=blue
    [ "$(active_slot)" = "blue" ] && idle=green
    run_slot "${idle}" "${target}"
    gate_slot "${idle}" "${target}"
    point_at "${idle}"
    reload_edge
    sleep 0.3
    expect_edge "${target}"
    ledger_add rollback "${target}" "${idle}" "一键回滚演示（验收：<60s 全程）" "${cur}" >/dev/null
    note "[ok] 账本追加：rollback ${cur} → ${target} @ ${idle}（含版本/时间/原因）"
}

do_recon() {
    step "recon" "三方对账：账本指针 ↔ 容器镜像/标签 ↔ 线上版本"
    local read action version slot image
    read -r action version slot image <<< "$(ledger_last)"
    local live label img
    live="$(edge_version | tr -d '\n')"
    label="$(docker inspect -f '{{index .Config.Labels "version"}}' "slot-${slot}")"
    img="$(docker inspect -f '{{.Config.Image}}' "slot-${slot}")"
    [ "${label}" = "${version}" ] \
        || { echo "        [!] 容器标签 ${label} ≠ 账本版本 ${version}" >&2; exit 1; }
    [ "${img}" = "${image}" ] \
        || { echo "        [!] 容器镜像 ${img} ≠ 账本镜像 ${image}" >&2; exit 1; }
    [ "${live}" = "${version}" ] \
        || { echo "        [!] 线上 /version=${live} ≠ 账本版本 ${version}" >&2; exit 1; }
    note "[ok] 三方一致：账本最新记录 ${action} ${version} @ ${slot}（${image}）"
    note "     = 容器标签 ${label} + 镜像 ${img} = 线上 /version ${live}"
}

do_clean() {
    step "clean" "销毁环境（账本随 .logs 清除）"
    docker rm -f "${EDGE_NAME}" slot-blue slot-green >/dev/null 2>&1 || true
    docker network rm "${NET}" >/dev/null 2>&1 || true
    point_at blue
    rm -rf "${LOGS}"
    note "[ok] 容器/网络已清；active.conf 已复位；账本已随日志清除"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)      do_up ;;
        deploy)  do_deploy "${2:?需要版本参数，如 deploy v2}" ;;
        rollback) do_rollback "${2:?需要版本参数，如 rollback v1}" ;;
        recon)   do_recon ;;
        clean)   do_clean ;;
        all)
            do_up
            local t0 t1
            t0="$(now_s)"
            do_deploy v2
            do_deploy v3
            do_rollback v1
            do_recon
            t1="$(now_s)"
            python3 -c "import sys; sys.exit(0 if $t1-$t0 < 60 else 1)" \
                || { echo "        [!] v2→v3→回滚→对账耗时 $(python3 -c "print(f'{$t1-$t0:.1f}')")s ≥ 60s" >&2; exit 1; }
            note "[ok] v2→v3→一键回滚→对账全程 $(python3 -c "print(f'{$t1-$t0:.1f}')")s（< 60s）"
            do_clean
            ;;
        *) echo "可用: up | deploy <v> | rollback <v> | recon | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
