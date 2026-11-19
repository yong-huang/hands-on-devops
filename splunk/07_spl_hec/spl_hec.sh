#!/usr/bin/env bash
# =============================================================================
# 07 · HEC 实时接入 — 主演示脚本
#
# 开启 HEC（HTTP Event Collector，进程经 HTTP 直推 JSON 事件的入库通道）：
# 单事件 ack 回执 → 1 万条批量 → 入库数对账 → 事件时间 vs 接收时间断言。
#
# ./spl_hec.sh up        确保 splunk 在跑（复用 lab 01 实例）
# ./spl_hec.sh deploy    部署 inputs.conf（开 HEC + token）+ 重启 + 健康探活
# ./spl_hec.sh ack       单事件 ack 回执断言（ackId → /ack 确认 true）
# ./spl_hec.sh batch     1 万条批量产生 + 入库数对账（差额=0）
# ./spl_hec.sh timecheck _time 用事件时间而非接收时间（滞后 ≈5400s 断言）
# ./spl_hec.sh clean     删 hec_demo 索引 + 删 inputs.conf + 重启归零
# ./spl_hec.sh all       up → deploy → ack → batch → timecheck → clean
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPLD="https://localhost:28089"
HEC="https://localhost:28088"
LAB01="../01_splunk_deploy"
# token 与 configs/inputs.conf 保持一致（本机实验用，随仓库公开）
TOKEN="$(grep '^token' configs/inputs.conf | awk '{print $3}')"
CHANNEL="$(python3 -c "import uuid; print(uuid.uuid4().hex)")"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

load_env() {
    [ -f "$LAB01/.env" ] || fail "缺 $LAB01/.env——先做 lab 01"
    set -a; # shellcheck disable=SC1090
    source "$LAB01/.env"; set +a
    [ -n "${SPLUNK_PASSWORD:-}" ] || fail "SPLUNK_PASSWORD 为空"
    [ -n "$TOKEN" ] || fail "token 解析失败（configs/inputs.conf）"
}

spl_search() {  # <SPL> → 结果 JSON（REST 前缀规则见 lab 02）
    local s="$1" pfx
    case "$s" in
        "|"*|tstats*|search*) pfx="" ;;
        *) pfx="search " ;;
    esac
    curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/search/jobs" \
        --data-urlencode "search=${pfx}${s}" \
        --data-urlencode "exec_mode=oneshot" \
        --data-urlencode "output_mode=json" \
        --data-urlencode "earliest_time=0"
}

qcount() { spl_search "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['results'][0].values())[0] if d.get('results') else 0)"; }

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
    step up "确保 splunk 在跑"
    if ! curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/server/info" 2>/dev/null | grep -q 'version'; then
        docker compose -f "$LAB01/docker-compose.yml" up -d 2>&1 | sed 's/^/        /'
        wait_splunk "冷启动"
    else
        note "[ok] splunk-deploy 已在运行"
    fi
}

do_deploy() {
    load_env
    step deploy "部署 inputs.conf（开 HEC + token）+ 建目标索引 + 重启"
    # 先建目标索引：HEC 的 intake 与 indexing 解耦——索引不存在时入库侧仍返回
    # code=0（甚至 ack=true），事件却被静默丢弃（实测踩过：0 条入库）
    local code
    code=$(curl -sk -u "admin:${SPLUNK_PASSWORD}" -o /dev/null -w '%{http_code}' "$SPLD/services/data/indexes/hec_demo")
    if [ "$code" = "200" ]; then note "[ok] 索引 hec_demo 已存在"; else
        docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add index hec_demo \
            -auth "admin:${SPLUNK_PASSWORD}" >/dev/null && note "[ok] 索引 hec_demo 已创建"
    fi
    docker cp configs/inputs.conf splunk-deploy:/opt/splunk/etc/system/local/inputs.conf
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "配置生效重启"
    # HEC 的 8088 监听比 splunkd 晚就绪——用 /health 探活轮询
    local i=0 hcode
    note "等待 HEC 健康检查..."
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "HEC 120s 未就绪"
        hcode=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Splunk ${TOKEN}" "$HEC/services/collector/health" || true)
        [ "$hcode" = "200" ] && { note "[ok] HEC 就绪（HTTP 200，约 $((i*5))s）"; return 0; }
        sleep 5
    done
}

do_ack() {
    load_env
    step ack "单事件 ack 回执：POST event → ackId → POST ack → true"
    local now resp ack_id ack_resp
    now=$(python3 -c "import time; print(round(time.time(),3))")
    # ack 模式必须带 channel；响应携带 ackId
    resp=$(curl -sk -H "Authorization: Splunk ${TOKEN}" \
        --data "{\"time\": ${now}, \"sourcetype\": \"splk_hec_json\", \"index\": \"hec_demo\", \"event\": {\"seq\": -1, \"path\": \"/ack-demo\", \"status\": 200, \"clientip\": \"10.0.0.1\"}}" \
        "$HEC/services/collector/event?channel=${CHANNEL}")
    echo "        event 响应: ${resp}"
    ack_id=$(printf '%s' "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('code')==0, d; print(d['ackId'])")
    note "拿到 ackId=${ack_id}（useACK=true 生效）"
    # ack 语义是异步的：事件被索引管道处理完后 ack 才翻转 true——立即查询是
    # false（实测抓到 {'acks':{'0':false}}），轮询到 true 为止（≤60s）
    local i=0 ack_val=""
    note "轮询 ack 回执（事件处理完才翻转 true）..."
    while :; do
        i=$((i+1)); [ $i -gt 12 ] && fail "ack 60s 未翻转 true（最后响应：${ack_val}）"
        ack_val=$(curl -sk -H "Authorization: Splunk ${TOKEN}" \
            --data "{\"acks\": [${ack_id}]}" \
            "$HEC/services/collector/ack?channel=${CHANNEL}")
        printf '%s' "$ack_val" | python3 -c "
import json, sys
d = json.load(sys.stdin)
acks = d.get('acks', {})
# 实测形态：ackId 为键的对象 {'acks': {'0': True/False}}，不是文档示例的数组
sys.exit(0 if acks and all(v is True for v in acks.values()) else 1)" && break
        sleep 5
    done
    echo "        ack 响应:   ${ack_val}（第 ${i} 轮）"
    ok "断言 A：ackId=${ack_id} 经 /ack 确认翻转 → true（索引器回执语义）"
    # 落库对账：ack-demo 事件可检索
    local i=0 c=0
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "ack-demo 事件 120s 未可检索"
        c=$(qcount "index=hec_demo sourcetype=splk_hec_json path=/ack-demo | stats count")
        [ "$c" -ge 1 ] 2>/dev/null && break
        sleep 5
    done
    ok "ack-demo 事件已入库并可检索（${c} 条）"
}

do_batch() {
    load_env
    step batch "1 万条批量产生 + 入库数对账"
    mkdir -p tmp
    local summary
    summary=$(python3 hec_producer.py --count 10000 --batch 500 --token "$TOKEN")
    echo "        产生器摘要: ${summary}"
    printf '%s' "$summary" > tmp/prod.json
    python3 -c "
import json
d = json.load(open('tmp/prod.json'))
assert d['sent'] == 10000 and d['failures'] == 0, d"
    local secs
    secs=$(python3 -c "import json; print(json.load(open('tmp/prod.json'))['seconds'])")
    ok "发送侧：10000 条全部被 HEC 接受（20 批 × 500，${secs}s）"
    # 入库对账：轮询至恰好 10000（差额=0）。排除 ack 步骤的演示事件——
    # path=/ack-demo 实测可提取（JSON 字段自动抽取）
    local i=0 c=0
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "120s 后入库 ${c} ≠ 10000"
        c=$(qcount "index=hec_demo sourcetype=splk_hec_json path!=/ack-demo | stats count")
        [ "$c" -eq 10000 ] 2>/dev/null && break
        sleep 5
    done
    ok "断言 B：入库数 = 发送数 = 10000（差额 0，已排除 ack 演示事件）"
}

do_timecheck() {
    load_env
    step timecheck "_time 用事件时间而非接收时间"
    local base last lag
    base=$(python3 -c "import json; print(json.load(open('tmp/prod.json'))['base_ts'])")
    last=$(python3 -c "import json; print(json.load(open('tmp/prod.json'))['last_ts'])")
    # _time 的 min/max 与产生器事件时间范围对照（±3s 容差；同样排除 ack 演示事件）
    spl_search "index=hec_demo sourcetype=splk_hec_json path!=/ack-demo | stats min(_time) as mn, max(_time) as mx" \
        | python3 -c "
import json, sys
r = json.load(sys.stdin)['results'][0]
assert abs(float(r['mn']) - ${base}) <= 3 and abs(float(r['mx']) - ${last}) <= 3, r"
    ok "断言 C1：_time 范围与事件时间一致（base/last ±3s 内）"
    # stats 聚合里不能直接写算术——先 eval 出 lag 再 max（lab 02 同款规则）
    lag=$(spl_search "index=hec_demo sourcetype=splk_hec_json path!=/ack-demo | eval lag_s=_indextime-_time | stats max(lag_s) as lag" \
        | python3 -c "import json,sys; print(round(float(json.load(sys.stdin)['results'][0]['lag'])))")
    note "_indextime-_time ≈ ${lag}s（产生器把事件时间预置在过去 5400s，接受即验证）"
    [ "$lag" -ge 4800 ] && [ "$lag" -le 6000 ] \
        && ok "断言 C2：入库时间滞后 ≈5400s → _time 取自事件内 time 字段（非接收时刻）" \
        || fail "滞后 ${lag}s 不在预期区间 [4800,6000]"
}

do_clean() {
    load_env
    step clean "删 hec_demo 索引 + 删 inputs.conf + 重启归零"
    curl -sk -u "admin:${SPLUNK_PASSWORD}" -X DELETE "$SPLD/services/data/indexes/hec_demo" >/dev/null \
        && note "[ok] 索引 hec_demo 已删除"
    docker exec -u root splunk-deploy rm -f /opt/splunk/etc/system/local/inputs.conf
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "清理重启"
    rm -rf tmp
    ok "HEC 已停用、数据与配置零残留（出厂解析不受影响）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)        do_up ;;
        deploy)    do_deploy ;;
        ack)       do_ack ;;
        batch)     do_batch ;;
        timecheck) do_timecheck ;;
        clean)     do_clean ;;
        all)       do_up; do_deploy; do_ack; do_batch; do_timecheck; do_clean ;;
        *) echo "可用: up | deploy | ack | batch | timecheck | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
