#!/usr/bin/env bash
# =============================================================================
# 11 · 告警引擎 — 主演示脚本
#
# 调度搜索（cron */2）+ webhook 告警动作 → 本机接收器。断言：
#   A  调度送达载荷含 search_name 与结果
#   B  3 次 cron 调度到达间隔与 */2 一致（±10s）
#
# ./spl_alerts.sh up       splunk 就绪 + 部署告警配置 + 重启 + 接收器起
# ./spl_alerts.sh wait     等 3 次 cron 调度送达并断言载荷与间隔
# ./spl_alerts.sh clean    删告警配置 + 停接收器 + 重启归零
# ./spl_alerts.sh all      up → wait → clean
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPLD="https://localhost:28089"
LAB01="../01_splunk_deploy"
ALERT="hec_errorrate_alert"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

load_env() {
    [ -f "$LAB01/.env" ] || fail "缺 $LAB01/.env——先做 lab 01"
    set -a; # shellcheck disable=SC1090
    source "$LAB01/.env"; set +a
    [ -n "${SPLUNK_PASSWORD:-}" ] || fail "SPLUNK_PASSWORD 为空"
}

wait_splunk() {
    local tag="$1" i=0
    note "等待 splunkd 就绪（${tag}）..."
    while :; do
        i=$((i+1)); [ $i -gt 84 ] && fail "$tag 420s 未就绪"
        curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/server/info" 2>/dev/null | grep -q 'version' \
            && { note "[ok] 就绪（约 $((i*5))s）"; return 0; }
        sleep 5
    done
}

do_up() {
    load_env
    step up "splunk 就绪 + 部署告警配置 + 接收器起"
    if ! curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/server/info" 2>/dev/null | grep -q 'version'; then
        docker compose -f "$LAB01/docker-compose.yml" up -d 2>&1 | sed 's/^/        /'
        wait_splunk "冷启动"
    else
        note "[ok] splunk-deploy 已在运行"
    fi
    # SavedSplunker 只执行"有应用上下文"的调度搜索——system/local 级会被拒绝
    # （实测日志：cannot execute scheduled searches that live at the system level）
    # 幂等：清掉 system/local 旧副本与旧应用包，再以 app 形式部署
    docker exec -u root splunk-deploy sh -c "rm -f /opt/splunk/etc/system/local/savedsearches.conf /opt/splunk/etc/system/local/alert_actions.conf; rm -rf /opt/splunk/etc/apps/lab_alerts"
    docker exec -u root splunk-deploy rm -rf /opt/splunk/etc/apps/lab_alerts
    docker cp configs/alerts_app splunk-deploy:/opt/splunk/etc/apps/lab_alerts
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "告警配置生效重启"
    # 接收器起在宿主机 :28321，容器经 host.docker.internal 访问
    # 先杀残留实例（端口占用会让新接收器起失败，旧实例写进已删目录=送达黑洞）
    pkill -f webhook_receiver 2>/dev/null || true
    sleep 1
    rm -rf tmp && mkdir -p tmp
    nohup python3 webhook_receiver.py tmp > tmp/receiver.log 2>&1 &
    echo $! > tmp/receiver.pid
    sleep 2
    grep -q "webhook receiver" tmp/receiver.log && note "[ok] 接收器已起（:28321 → tmp/）"
    # 调度已登记确认
    curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/servicesNS/nobody/lab_alerts/saved/searches/$ALERT?output_mode=json" \
        | python3 -c "
import json, sys
c = json.load(sys.stdin)['entry'][0]['content']
assert c['cron_schedule'] == '*/2 * * * *' and c['is_scheduled'] in (True, '1'), c
print('        [ok] 调度已登记：cron */2 · 已启用')"
    ok "up 完成"
}

do_wait() {
    load_env
    step wait "等 3 次 cron 调度送达（*/2）→ 载荷与间隔断言"
    note "动作只由调度器触发（手动 dispatch 不触发动作，实测）；3 次送达约 4-6 分钟"
    local i=0 n
    while :; do
        i=$((i+1)); [ $i -gt 120 ] && fail "600s 内调度送达 <3 次"
        n=$(find tmp -name 'webhook_*.json' 2>/dev/null | wc -l | tr -d ' ')
        [ "$n" -ge 3 ] 2>/dev/null && { note "[ok] 已累计 ${n} 次调度送达"; break; }
        sleep 5
    done
    python3 - <<'PYEOF'
import glob, json
recs = sorted((json.load(open(f, encoding="utf-8")) for f in glob.glob("tmp/webhook_*.json")),
              key=lambda r: r["arrived_epoch"])
sched = [r for r in recs if r["payload"].get("search_name") == "hec_errorrate_alert"]
assert len(sched) >= 3, f"载荷含 search_name 的送达不足 3 次：{len(sched)}"
sched = sched[-3:]
first = sched[0]
res = first["payload"].get("result") or first["payload"].get("results")
assert res, "payload 缺 results/result 字段"
print(f"        ✅ 断言 A：调度送达载荷含 search_name 与结果（result={res}）")
gaps = [round(sched[i+1]["arrived_epoch"] - sched[i]["arrived_epoch"]) for i in range(2)]
for r in sched:
    print(f"        {r['arrived_str']}  search_name={r['payload']['search_name']}")
print(f"        相邻间隔: {gaps[0]}s, {gaps[1]}s（cron */2 = 120s，容差 ±10s）")
assert all(110 <= g <= 130 for g in gaps), gaps
print("        ✅ 断言 B：3 次调度间隔与 cron 表达式一致")
PYEOF
    ok "断言 B 通过（明细见上）"
}

do_clean() {
    load_env
    step clean "停接收器 + 删告警配置 + 重启归零"
    [ -f tmp/receiver.pid ] && kill "$(cat tmp/receiver.pid)" 2>/dev/null || true
    docker exec -u root splunk-deploy rm -rf /opt/splunk/etc/apps/lab_alerts
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "清理重启"
    rm -rf tmp
    ok "告警配置零残留（调度随 savedsearches.conf 移除而停）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)      do_up ;;
wait)    do_wait ;;
        clean)   do_clean ;;
        all)     do_up; do_wait; do_clean ;;
        *) echo "可用: up | wait | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
