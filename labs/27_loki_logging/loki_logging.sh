#!/usr/bin/env bash
# =============================================================================
# 27 · 集中日志（Loki 轻量栈）— 主演示脚本
#
# 生成器模拟 CI 作业日志 → Promtail 抓文件（job=ci, app=ci 标签）→ Loki 存储
# → LogQL 查询（行数/ERROR 计数/速率）→ ruler 告警（ERROR 速率>0）→
# Alertmanager → webhook 接收器 → Grafana provisioning 断言。
#
# ./loki_logging.sh up      起栈（Loki+Promtail+生成器+Grafana+AM+receiver）
# ./loki_logging.sh query   LogQL 断言（日志行入库、ERROR 计数、速率查询）
# ./loki_logging.sh alert   ruler 告警 firing → AM → webhook 送达三重断言
# ./loki_logging.sh grafana Loki datasource provisioning + 代理查询断言
# ./loki_logging.sh down    销毁
# ./loki_logging.sh all     up → query → alert → grafana → down（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

L="http://localhost:29200"
AM="http://localhost:29293"
LOGS=".logs"

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

logql() {  # logql <query> [limit] → JSON
    curl -sS --get --data-urlencode "query=$1" \
        --data-urlencode "limit=${2:-100}" "$L/loki/api/v1/query_range" 2>/dev/null
}

metricq() {  # metricq <query> → 值列表
    curl -sS --get --data-urlencode "query=$1" "$L/loki/api/v1/query" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('data', {}).get('result', []):
    print(r['value'][1])"
}

do_up() {
    step up "启动六件栈（Loki 3.1 + Promtail + 生成器 + Grafana + AM + receiver）"
    mkdir -p tmp/logs tmp/positions tmp/loki "$LOGS"
    : > tmp/logs/app.log
    docker compose up -d --wait 2>&1 | tail -2 | sed 's/^/        /' || fail "compose up 失败"
    wait_http "$L/ready" "Loki"
    wait_http "http://localhost:29201/api/health" "Grafana"
    wait_http "$AM/-/ready" "Alertmanager"
    note "Loki :29200 · Grafana :29201 (admin/admin) · AM :29293 · receiver :29294"
}

do_query() {
    step query "LogQL：日志入库与查询断言"
    # 生成器 2s/行：等一批日志入库（promtail 抓取 + loki 入库有秒级延迟）
    local n=0 streams=0
    while :; do
        n=$((n+1)); [ $n -gt 20 ] && fail "60s 内无日志流入 Loki"
        streams=$(logql '{app="ci"}' 50 | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(sum(len(s.get('values', [])) for s in d.get('data', {}).get('result', [])))" 2>/dev/null || echo 0)
        [ "${streams:-0}" -ge 10 ] && break
        sleep 3
    done
    ok "日志已入库：{app=\"ci\"} 命中 $streams 行（>10）"

    step query "ERROR 计数与速率查询"
    # 生成器每 5 行一条 ERROR（约 10s/条）——轮询等 ≥2 条，别硬断言
    local n=0 errs=0
    while :; do
        n=$((n+1)); [ $n -gt 20 ] && fail "60s 内 ERROR 计数未达 2（实为 ${errs:-0}）"
        errs=$(metricq 'sum(count_over_time({app="ci"} |= "ERROR" [5m]))')
        [ "${errs:-0}" -ge 2 ] && break
        sleep 3
    done
    ok "ERROR 计数：$errs 条/5m"
    local rate
    rate=$(metricq 'sum(rate({app="ci"} |= "ERROR" [1m]))')
    [ -n "$rate" ] || fail "rate 查询无结果"
    ok "rate 查询：$rate 行/s"
    note "Grafana Explore 即以上 LogQL（datasource 已 provisioning）"
}

do_alert() {
    step alert "ruler 告警（ERROR 速率>0）→ AM → webhook 断言"
    # 注：Loki 3.1 local-storage 模式下 /loki/api/v1/rules 返回规则文件原文
    # （非 JSON），断言改用下游权威证据：AM alerts + webhook 载荷；
    # ruler 评估本身以 loki 日志旁证（"Starting rule manager" + executing query）
    local n=0 am=""
    while :; do
        n=$((n+1)); [ $n -gt 40 ] && fail "120s 内 CILogErrorRate 未送达 AM"
        am=$(curl -sS "$AM/api/v2/alerts" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(','.join(sorted({a['labels'].get('alertname','') for a in d})))" 2>/dev/null)
        echo "$am" | grep -q "CILogErrorRate" && break
        sleep 3
    done
    ok "Alertmanager 收到 CILogErrorRate（ruler 评估触发）"

    n=0
    while :; do
        n=$((n+1)); [ $n -gt 15 ] && fail "webhook 未收到告警"
        local got
        got=$(curl -sS "http://localhost:29294/count" 2>/dev/null || echo 0)
        [ "${got:-0}" -ge 1 ] && break
        sleep 2
    done
    python3 -c "
import json
d = json.load(open('tmp/alerts.json'))
names = sorted({a['labels'].get('alertname','') for a in d})
assert 'CILogErrorRate' in names, names
print('        receiver 载荷含:', ', '.join(names))"
    ok "webhook 送达 $got 条（Loki ruler → AM → receiver 真实链路）"
}

do_grafana() {
    step grafana "Loki datasource provisioning + 代理查询断言"
    local auth="admin:admin"
    local ds
    ds=$(curl -sS -u "$auth" "http://localhost:29201/api/datasources/name/Loki" 2>/dev/null)
    echo "$ds" | grep -q '"type":"loki"' || fail "Loki datasource 未 provision"
    ok "datasource Loki 已导入"
    local dsid
    dsid=$(echo "$ds" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    # 经 Grafana 代理查 Loki 标签（datasource→loki 链路）
    local labels
    labels=$(curl -sS -u "$auth" "http://localhost:29201/api/datasources/proxy/$dsid/loki/api/v1/labels" 2>/dev/null)
    echo "$labels" | grep -q '"app"' || fail "Grafana→Loki 代理查询失败（标签无 app）"
    ok "Grafana 代理查询返回标签集（含 app）——面板数据链路通"
}

do_down() {
    step down "销毁"
    docker compose down -v 2>&1 | tail -1 | sed 's/^/        /'
    note "[ok] 零残留"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)      do_up ;;
        query)   do_query ;;
        alert)   do_alert ;;
        grafana) do_grafana ;;
        down)    do_down ;;
        all)     do_up; do_query; do_alert; do_grafana; do_down ;;
        *) echo "可用: up | query | alert | grafana | down | all" >&2; exit 1 ;;
    esac
}

main "$@"
