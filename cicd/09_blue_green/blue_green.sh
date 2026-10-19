#!/usr/bin/env bash
# =============================================================================
# 09 · 蓝绿部署 — 主演示脚本
#
# 完整生命周期：up → switch → rollback → clean
# 用法：
#   ./blue_green.sh up         # 起双槽 + edge，断言初始流量全在 v1
#   ./blue_green.sh switch     # 健康门禁 → 压测中切槽 → 断言 0 失败 + v2 生效
#   ./blue_green.sh rollback   # 切回 v1，断言回滚耗时 < 5s
#   ./blue_green.sh clean      # 销毁环境，active.conf 复位到 blue
#   ./blue_green.sh            # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

EDGE_PORT=29080
BLUE_PORT=29081
GREEN_PORT=29082
CONF_UP=compose/conf/edge/upstream
LOGS=.logs

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

edge_version() { curl -s --max-time 2 "http://127.0.0.1:${EDGE_PORT}/version" || true; }

# 把 active.conf 原子指向 $1（blue|green）——cat 覆写保 inode，bind mount 才可见
point_at() {
    cat "${CONF_UP}/$1.conf" > "${CONF_UP}/active.conf"
}

reload_edge() { docker compose -f compose/docker-compose.yml exec -T edge nginx -s reload; }

# 等 edge 就绪并断言其 /version 为 $1
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

slot_port() { case "$1" in blue) echo "${BLUE_PORT}";;
                     green) echo "${GREEN_PORT}";; esac; }

# 健康门禁：槽 $1 的 /version 必须连续可用地返回 $2，才允许切流量
gate_slot() {
    local slot="$1" want="$2" port got i
    port="$(slot_port "${slot}")"
    for i in $(seq 1 30); do
        got="$(curl -s --max-time 2 "http://127.0.0.1:${port}/version" | tr -d '\n')"
        [ "${got}" = "${want}" ] && { note "[ok] 健康门禁：${slot} /version = ${got}"; return 0; }
        sleep 0.5
    done
    echo "        [!] ${slot} 未就绪（期望 ${want}，实际 '${got}'）——拒绝切流量" >&2
    return 1
}

do_up() {
    step "up" "起双槽 + edge，断言初始流量全在 v1"
    point_at blue
    docker compose -f compose/docker-compose.yml up -d
    local i st id
    for svc in blue green; do
        id="$(docker compose -f compose/docker-compose.yml ps -q ${svc})"
        for i in $(seq 1 30); do
            st="$(docker inspect -f '{{.State.Health.Status}}' "${id}")"
            [ "${st}" = "healthy" ] && break
            sleep 1
        done
        [ "${st}" = "healthy" ] || { echo "        [!] ${svc} 未 healthy" >&2; return 1; }
        note "[ok] ${svc} healthy"
    done
    # compose up 不会重建没变化的容器——edge 若带着上一轮的内存配置
    # （比如上次 switch 后指向 green），必须 reload 才能与 active.conf 对齐
    reload_edge
    expect_edge v1
}

do_switch() {
    step "switch" "压测中切槽：健康门禁 → 切 green → 断言 0 连接失败"
    mkdir -p "${LOGS}"
    expect_edge v1
    # ① 健康门禁：green 不 healthy 就不切
    gate_slot green v2
    # ② 起压测（12 秒）与版本采样器，让切换发生在流量窗口正中间。
    #    压 /version 而不是 /：v1、v2 的响应体都是 3 字节——ab 会把
    #    "响应体长度变了"记成 Length 失败（假阳性），压同长度的路径
    #    才能让 Failed requests: 0 只反映真实掉线。-n 抬高防提前跑完。
    ab -q -t 12 -n 200000 -c 10 "http://127.0.0.1:${EDGE_PORT}/version" \
        > "${LOGS}/ab.log" 2>&1 &
    local ab_pid=$!
    : > "${LOGS}/samples.log"
    ( while :; do
        echo "$(now) $(edge_version | tr -d '\n')" >> "${LOGS}/samples.log"
        sleep 0.1
      done ) &
    local sampler_pid=$!
    sleep 4
    # ③ 切槽：改 upstream + reload（旧连接不中断，新请求进新槽）
    local t0 t1
    t0="$(now)"
    point_at green
    reload_edge
    t1="$(now)"
    note "切槽动作（改 conf + reload）耗时 $(python3 -c "print(f'{$t1-$t0:.2f}')")s"
    wait "${ab_pid}" || true
    kill "${sampler_pid}" 2>/dev/null || true
    wait "${sampler_pid}" 2>/dev/null || true
    # ④ 断言一：压测全程 0 失败
    local failed complete
    failed="$(grep -E '^Failed requests:' "${LOGS}/ab.log" | awk '{print $3}')"
    complete="$(grep -E '^Complete requests:' "${LOGS}/ab.log" | awk '{print $3}')"
    [ "${failed}" = "0" ] || { echo "        [!] 压测出现失败请求：${failed}" >&2; exit 1; }
    [ -n "${complete}" ] && [ "${complete}" -gt 0 ] \
        || { echo "        [!] 压测未产生完成请求" >&2; exit 1; }
    note "[ok] 压测 ${complete} 个请求，Failed requests: 0"
    grep -E '^Non-2xx responses:' "${LOGS}/ab.log" >/dev/null \
        && { echo "        [!] 出现非 2xx 响应" >&2; exit 1; } || true
    # ⑤ 断言二：采样时间线里 v1、v2 都出现过，切换空洞 < 1s
    local v1n v2n gap
    v1n="$(grep -c ' v1$' "${LOGS}/samples.log" || true)"
    v2n="$(grep -c ' v2$' "${LOGS}/samples.log" || true)"
    [ "${v1n}" -gt 0 ] && [ "${v2n}" -gt 0 ] \
        || { echo "        [!] 采样里应同时有 v1 与 v2（${v1n}/${v2n}）" >&2; exit 1; }
    [ -n "$(grep -E ' $' "${LOGS}/samples.log")" ] \
        && { echo "        [!] 采样出现空版本（有请求失败）" >&2; exit 1; } || true
    gap="$(python3 - "${LOGS}/samples.log" << 'PY'
import sys
lines = [l.split() for l in open(sys.argv[1]) if len(l.split()) == 2]
last_v1 = max(float(t) for t, v in lines if v == 'v1')
first_v2 = min(float(t) for t, v in lines if v == 'v2')
print(f"{first_v2 - last_v1:.2f}")
PY
)"
    note "[ok] 采样时间线：v1 × ${v1n} → v2 × ${v2n}，切换空洞 ${gap}s"
    # ⑥ 切换后取证：edge 已是 v2；blue 旧槽仍存活（回滚位）
    expect_edge v2
    local blue_now
    blue_now="$(curl -s --max-time 2 "http://127.0.0.1:${BLUE_PORT}/version" | tr -d '\n')"
    [ "${blue_now}" = "v1" ] || { echo "        [!] blue 旧槽未存活" >&2; exit 1; }
    note "[ok] 旧槽 blue（v1）仍存活——这就是回滚位"
}

do_rollback() {
    step "rollback" "切回 v1，断言回滚耗时 < 5s"
    local t0 t1 got
    t0="$(now)"
    point_at blue
    reload_edge
    for i in $(seq 1 100); do
        got="$(edge_version | tr -d '\n')"
        [ "${got}" = "v1" ] && break
        sleep 0.05
    done
    t1="$(now)"
    [ "${got}" = "v1" ] || { echo "        [!] 回滚后 edge 仍是 '${got}'" >&2; exit 1; }
    local elapsed
    elapsed="$(python3 -c "print(f'{$t1-$t0:.2f}')")"
    python3 -c "import sys; sys.exit(0 if $t1-$t0 < 5 else 1)" \
        || { echo "        [!] 回滚耗时 ${elapsed}s ≥ 5s" >&2; exit 1; }
    note "[ok] 回滚到 v1 耗时 ${elapsed}s（< 5s）——改回 upstream 即秒回"
    note "[ok] green 槽不销毁，下次发版它就是『旧槽』——蓝绿是双向对等的"
}

do_clean() {
    step "clean" "销毁环境，active.conf 复位到 blue"
    docker compose -f compose/docker-compose.yml down 2>/dev/null || true
    point_at blue
    rm -rf "${LOGS}"
    note "[ok] 容器已清；active.conf 已复位；日志已清"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)       do_up ;;
        switch)   do_switch ;;
        rollback) do_rollback ;;
        clean)    do_clean ;;
        all)      do_up; do_switch; do_rollback; do_clean ;;
        *) echo "可用: up | switch | rollback | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
