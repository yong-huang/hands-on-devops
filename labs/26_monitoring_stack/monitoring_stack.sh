#!/usr/bin/env bash
# =============================================================================
# 26 · 监控栈 — 主演示脚本
#
# Prometheus + Grafana + node-exporter + pushgateway + Alertmanager + webhook
# 接收器。CI 作业指标经 pushgateway 推入（构建次数/时长/成功失败），告警规则
# （失败率>0、队列积压）经 Alertmanager 真实送达 webhook 接收器。
#
# ./monitoring_stack.sh up            起六件栈 + 抓取健康断言
# ./monitoring_stack.sh push-metrics  推 CI 作业指标（成功×3 + 失败×1 + 队列积压）
# ./monitoring_stack.sh curves        三条曲线断言（构建次数/时长/成功率）
# ./monitoring_stack.sh alert         告警真实触发 → webhook 送达断言
# ./monitoring_stack.sh grafana       Grafana provisioning 断言（datasource+dashboard）
# ./monitoring_stack.sh down          销毁
# ./monitoring_stack.sh all           up → push → curves → alert → grafana → down
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

P="http://localhost:29190"
AM="http://localhost:29193"
PG="http://localhost:29191"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

wait_http() {
    local url="$1" name="$2" i=0
    until curl -fsS "$url" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 60 ] && fail "$name 120s 未就绪"
        sleep 2
    done
    note "[ok] $name 就绪"
}

q() {  # q <promql> → 输出查询结果值（多个）
    curl -sS --get --data-urlencode "query=$1" "$P/api/v1/query" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('data', {}).get('result', []):
    print(r['value'][1])"
}

do_up() {
    step up "启动六件栈（钉版本）"
    docker compose up -d --wait 2>&1 | tail -2 | sed 's/^/        /' || fail "compose up 失败"
    wait_http "$P/-/ready" "Prometheus"
    wait_http "$AM/-/ready" "Alertmanager"
    wait_http "$PG/-/healthy" "Pushgateway"
    wait_http "http://localhost:29101/api/health" "Grafana"
    # 首次 scrape 需 1-2 个抓取周期——轮询而非立即断言
    local n=0 up=""
    while :; do
        n=$((n+1)); [ $n -gt 20 ] && fail "node-exporter up 序列 60s 未出现（实为 ${up:-无}）"
        up=$(q 'up{job="node-exporter"}')
        [ "$up" = "1" ] && break
        sleep 3
    done
    ok "抓取健康：node-exporter up=1"
    note "Prometheus :9090 · Grafana :3001 (admin/admin) · Pushgateway :9091 · Alertmanager :9093 · receiver :9094"
}

do_push_metrics() {
    step push-metrics "推 CI 作业指标（模拟流水线产物）"
    # 成功构建 ×3（时长不同）、失败 ×1、队列积压 2
    local i
    for i in 1 2 3; do
        echo "ci_builds_total{status=\"success\"} 1" | curl -sS --data-binary @- "$PG/metrics/job/demo/instance/build$i" >/dev/null
        echo "ci_build_duration_seconds 12.$i" | curl -sS --data-binary @- "$PG/metrics/job/demo/instance/build$i" >/dev/null
    done
    echo "ci_builds_total{status=\"failure\"} 1" | curl -sS --data-binary @- "$PG/metrics/job/demo/instance/build4" >/dev/null
    echo "ci_queue_depth 2" | curl -sS --data-binary @- "$PG/metrics/job/demo/instance/queue" >/dev/null
    ok "已推：成功×3（含时长）、失败×1、队列深度 2"
    note "验证样例：curl -s '$P/api/v1/query?query=sum(ci_builds_total)'" | sed 's/验证样例/        查询/'
}

do_curves() {
    step curves "三条曲线断言（构建次数/时长/成功率）"
    # push 的指标要等 Prometheus 下一轮抓 pushgateway 才可见（5s 周期）
    local n=0 w=""
    while :; do
        n=$((n+1)); [ $n -gt 20 ] && fail "push 指标 60s 未被抓取"
        w=$(q 'sum(ci_builds_total)')
        [ "${w:-}" = "4" ] && break
        sleep 3
    done
    ok "pushgateway 指标已被抓取（sum=4）"
    local t rate
    n=$(q 'sum(ci_builds_total)')          ; [ "$(python3 -c "print(float('${n:-0}'))")" = "4.0" ] || fail "构建总数应为 4，实为 ${n:-无}"
    ok "构建次数曲线：总数 ${n}（成功 3 + 失败 1）"
    t=$(q 'ci_build_duration_seconds' | head -1); [ -n "$t" ] || fail "构建时长无数据"
    ok "构建时长曲线：样例 $t 秒"
    rate=$(q 'sum(ci_builds_total{status="success"}) / sum(ci_builds_total)')
    [ "$(python3 -c "print(round(float('${rate:-0}'), 2))")" = "0.75" ] || fail "成功率应 0.75，实为 $rate"
    ok "成功率曲线：${rate}（75%）"
    note "Grafana 面板三图即以上三条 query（provisioning 自动导入）"
}

do_alert() {
    step alert "告警规则真实触发 → Alertmanager → webhook 送达"
    # 失败率 1/4>0 与 队列 depth=2 均应触发（for: 0s 立即 firing）
    local n=0 firing=""
    while :; do
        sleep 3; n=$((n+1)); [ $n -gt 20 ] && fail "60s 内告警未 firing"
        firing=$(curl -sS "$AM/api/v2/alerts" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
names = [a['labels'].get('alertname') for a in d if a.get('status', {}).get('state') in ('active', 'suppressed')]
print(','.join(sorted(names)))" 2>/dev/null)
        echo "$firing" | grep -q "BuildFailureRateHigh" && echo "$firing" | grep -q "QueueBacklog" && break
    done
    ok "两条告警 firing：$firing"
    n=0
    while :; do
        sleep 2; n=$((n+1)); [ $n -gt 15 ] && fail "webhook 未收到告警"
        local got
        got=$(curl -sS "http://localhost:29194/count" 2>/dev/null || echo 0)
        [ "${got:-0}" -ge 2 ] && break
    done
    ok "webhook 送达 $got 条（Alertmanager → receiver 真实链路）"
    curl -sS "http://localhost:29194/last" >/dev/null 2>&1 || true
    python3 -c "
import json
d = json.load(open('tmp/alerts.json'))
names = sorted({a['labels'].get('alertname','') for a in d})
assert 'BuildFailureRateHigh' in names and 'QueueBacklog' in names, names
print('        receiver 记录含:', ', '.join(names))"
    ok "webhook 载荷校验通过"
}

do_grafana() {
    step grafana "Grafana provisioning 断言（datasource + dashboard）"
    local auth="admin:admin"
    local ds
    ds=$(curl -sS -u "$auth" "http://localhost:29101/api/datasources/name/Prometheus" 2>/dev/null)
    echo "$ds" | grep -q '"type":"prometheus"' || fail "datasource 未 provision"
    ok "datasource Prometheus 已导入"
    local search
    search=$(curl -sS -u "$auth" "http://localhost:29101/api/search?query=CI" 2>/dev/null)
    echo "$search" | grep -q "ci-pipeline-26" || fail "dashboard 未 provision"
    ok "dashboard「CI 流水线（实验 26）」已导入（uid ci-pipeline-26）"
    # 经 Grafana 代理查询 Prometheus（datasource→prom 链路）
    local proxy
    proxy=$(curl -sS -u "$auth" -G --data-urlencode 'query=sum(ci_builds_total)' \
        "http://localhost:29101/api/datasources/proxy/1/api/v1/query" 2>/dev/null)
    echo "$proxy" | grep -q '"4"' || fail "Grafana→Prometheus 代理查询失败"
    ok "Grafana 代理查询返回 sum(ci_builds_total)=4（面板数据链路通）"
}

do_down() {
    step down "销毁"
    docker compose down -v 2>&1 | tail -1 | sed 's/^/        /'
    note "[ok] 零残留"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)           do_up ;;
        push-metrics) do_push_metrics ;;
        curves)       do_curves ;;
        alert)        do_alert ;;
        grafana)      do_grafana ;;
        down)         do_down ;;
        all)          do_up; do_push_metrics; do_curves; do_alert; do_grafana; do_down ;;
        *) echo "可用: up | push-metrics | curves | alert | grafana | down | all" >&2; exit 1 ;;
    esac
}

main "$@"
