#!/usr/bin/env bash
# =============================================================================
# 🏁 12 · 终极串联 — 主演示脚本
#
# demo-web 服务（stdlib http.server）双通道观测闭环：
#   HEC 直报（JSON）+ UF 文件采集（log 行）→ 同一索引 loop_demo
#   仪表盘（Studio JSON）+ 两条告警（错误率 / 服务下线）
#   演练：kill 服务 → 下线告警送达 → 重启 → 对账恢复
#
# ./spl_full_loop.sh up          索引器 + HEC + 索引 + 告警应用 + UF + 接收器
# ./spl_full_loop.sh webup       启动 demo-web（宿主 28330）
# ./spl_full_loop.sh traffic     50 个请求（含 10% /boom）
# ./spl_full_loop.sh reconcile   双通道对账断言（HEC + UF = 请求数，差额 0）
# ./spl_full_loop.sh drill       kill → 下线告警送达（≤300s）→ 重启 → 对账恢复
# ./spl_full_loop.sh clean       全部组件归零
# ./spl_full_loop.sh all         up → webup → traffic → reconcile → drill → clean
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPLD="https://localhost:28089"
LAB01="../01_splunk_deploy"
UF_NAME="uf-lab12"
NET="01_splunk_deploy_default"
UF_IMG="splunk/universalforwarder:9.4"
HEC_TOKEN="$(grep '^token' configs/inputs.conf | awk '{print $3}')"
WEB_PORT=28330

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

load_env() {
    [ -f "$LAB01/.env" ] || fail "缺 $LAB01/.env——先做 lab 01"
    set -a; # shellcheck disable=SC1090
    source "$LAB01/.env"; set +a
    [ -n "${SPLUNK_PASSWORD:-}" ] || fail "SPLUNK_PASSWORD 为空"
    [ -n "$HEC_TOKEN" ] || fail "token 解析失败"
}

spl_search() {
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

kill_receivers() { pkill -f webhook_receiver 2>/dev/null || true; sleep 1; }

do_up() {
    load_env
    step up "索引器 + HEC + loop_demo 索引 + 告警应用 + 接收器"
    if ! curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/server/info" 2>/dev/null | grep -q 'version'; then
        docker compose -f "$LAB01/docker-compose.yml" up -d 2>&1 | sed 's/^/        /'
        wait_splunk "冷启动"
    else
        note "[ok] splunk-deploy 已在运行"
    fi
    # 目标索引先建（lab 07 教训：缺索引静默丢弃）
    # 无条件删建：重复跑 all 时旧演练事件不残留（对账基准始终从 0 开始）
    curl -sk -u "admin:${SPLUNK_PASSWORD}" -X DELETE "$SPLD/services/data/indexes/loop_demo" >/dev/null 2>&1 || true
    docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add index loop_demo \
        -auth "admin:${SPLUNK_PASSWORD}" >/dev/null && note "[ok] 索引 loop_demo 已重建（幂等）"
    # DELETE 的物理清理是异步的——旧事件可能挂回重建后的索引（实测踩过：
    # 重建后 UF 通道 100=前次残留 50+本次 50）。轮询到归零才放行
    local j=0 c
    while :; do
        j=$((j+1)); [ $j -gt 24 ] && fail "重建后索引 120s 未归零（残留 ${c}）"
        c=$(qcount "index=loop_demo | stats count")
        [ "$c" = "0" ] 2>/dev/null && { note "[ok] 索引已归零（约 $((j*5))s）"; break; }
        sleep 5
    done
    # HEC 开启（lab 07 同款 inputs.conf）
    mkdir -p tmp configs
    if [ ! -f configs/s2s.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -keyout tmp/s2s.key \
            -out tmp/s2s.crt -days 365 -subj "/CN=splunk-s2s" 2>/dev/null
        cat tmp/s2s.crt tmp/s2s.key > configs/s2s.pem
        note "[ok] 自签证书已生成"
    fi
    docker cp configs/s2s.pem splunk-deploy:/opt/splunk/etc/auth/s2s.pem
    docker cp configs/inputs.conf splunk-deploy:/opt/splunk/etc/system/local/inputs.conf
    # 告警应用包（lab 11 同款：调度搜索必须住 app）
    docker exec -u root splunk-deploy rm -rf /opt/splunk/etc/apps/lab_loop_alerts
    # 逐文件精确拷贝——docker cp 整目录在目标已存在时会把 app 嵌套成
    # lab_loop_alerts/app/（实测踩过：应用结构破坏、savedsearches 丢失）
    docker exec -u root splunk-deploy mkdir -p /opt/splunk/etc/apps/lab_loop_alerts/default /opt/splunk/etc/apps/lab_loop_alerts/local
    docker cp configs/app/default/app.conf      splunk-deploy:/opt/splunk/etc/apps/lab_loop_alerts/default/app.conf
    docker cp configs/app/local/savedsearches.conf splunk-deploy:/opt/splunk/etc/apps/lab_loop_alerts/local/savedsearches.conf
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "配置生效重启"
    local i=0 hcode
    note "等待 HEC 健康检查..."
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "HEC 120s 未就绪"
        hcode=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Splunk ${HEC_TOKEN}" \
            "https://localhost:28088/services/collector/health" || true)
        [ "$hcode" = "200" ] && { note "[ok] HEC 就绪（HTTP 200）"; break; }
        sleep 5
    done
    # 接收器
    kill_receivers
    rm -rf tmp && mkdir -p tmp
    nohup python3 ../11_spl_alerts/webhook_receiver.py tmp > tmp/receiver.log 2>&1 &
    echo $! > tmp/receiver.pid
    sleep 2
    grep -q "webhook receiver" tmp/receiver.log && note "[ok] 接收器已起（:28321）"
    ok "up 完成"
}

do_webup() {
    load_env
    step webup "启动 demo-web（宿主 :28330）"
    pkill -f demo_web.py 2>/dev/null || true
    sleep 1
    nohup python3 demo_web.py --port "$WEB_PORT" --hec-token "$HEC_TOKEN" \
        --logfile tmp/demo_web.log > tmp/web.log 2>&1 &
    sleep 2
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${WEB_PORT}/health" || true)
    [ "$code" = "200" ] || fail "demo-web 健康探针失败（HTTP ${code}）"
    ok "demo-web 就绪（/health 200）"
}

do_ufup() {
    load_env
    step ufup "UF 容器接入（采集 demo_web.log）"
    docker rm -f "$UF_NAME" >/dev/null 2>&1 || true
    # demo_web.log 在宿主 tmp/，挂进 UF；outputs 指向索引器（lab 08 同款）
    mkdir -p tmp/uf
    docker run -d --name "$UF_NAME" --network "$NET" \
        -e SPLUNK_START_ARGS=--accept-license -e "SPLUNK_PASSWORD=${SPLUNK_PASSWORD}" \
        -v "$PWD/tmp:/opt/data" "$UF_IMG" >/dev/null
    local i=0
    while :; do
        i=$((i+1)); [ $i -gt 180 ] && fail "UF 900s 未完成引导"
        docker logs "$UF_NAME" 2>&1 | grep -q "Ansible playbook complete" \
            && { note "[ok] UF 引导完成"; break; }
        sleep 5
    done
    docker cp configs/uf/inputs.conf  "$UF_NAME:/opt/splunkforwarder/etc/system/local/inputs.conf"
    docker cp configs/uf/outputs.conf "$UF_NAME:/opt/splunkforwarder/etc/system/local/outputs.conf"
    docker restart "$UF_NAME" >/dev/null
    i=0
    while :; do
        i=$((i+1)); [ $i -gt 60 ] && fail "UF 重启后 300s 未就绪"
        docker exec -u root "$UF_NAME" /opt/splunkforwarder/bin/splunk status 2>/dev/null | grep -q 'is running' \
            && { note "[ok] UF 配置生效"; break; }
        sleep 5
    done
    ok "UF 就绪（monitor /opt/data/demo_web.log → 9997）"
}

do_traffic() {
    load_env
    step traffic "50 个请求（40 × /hit + 10 × /boom）"
    local i
    for i in $(seq 1 40); do curl -s "http://localhost:${WEB_PORT}/hit" >/dev/null; done
    for i in $(seq 1 10); do curl -s "http://localhost:${WEB_PORT}/boom" >/dev/null; done
    note "[ok] 50 个请求已发出（日志行数：$(wc -l < tmp/demo_web.log | tr -d ' ')）"
}

do_reconcile() {
    load_env
    step reconcile "双通道对账（UF 行数 = HEC 数 = 文件行数，差额 0）"
    local expected uf_c hec_c i=0
    expected=$(wc -l < tmp/demo_web.log | tr -d ' ')
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "UF 通道 120s 未追平（当前 ${uf_c:-0}/${expected}）"
        uf_c=$(qcount "index=loop_demo sourcetype=splk_demo_web | stats count")
        [ "$uf_c" -eq "$expected" ] 2>/dev/null && break
        sleep 5
    done
    hec_c=$(qcount "index=loop_demo sourcetype=splk_demo_hec | stats count")
    note "文件行数 ${expected} | UF 通道 ${uf_c} | HEC 通道 ${hec_c}"
    [ "$hec_c" = "$expected" ] || fail "HEC 通道 ${hec_c} ≠ ${expected}"
    ok "断言 A：双通道对账一致（UF=${uf_c}，HEC=${hec_c}，各等于文件行数 ${expected}，差额 0）"
}

do_drill() {
    load_env
    step drill "故障演练：kill demo-web → 下线告警送达 → 重启恢复"
    local t_kill
    t_kill=$(date +%s)
    local n0
    n0=$(find tmp -name 'webhook_*.json' 2>/dev/null | wc -l | tr -d ' ')
    pkill -f "demo_web.py" || true
    note "[ok] demo-web 已 kill（$(date '+%H:%M:%S')），基线送达 ${n0} 次"
    # 下线告警 cron */1 + 3 分钟窗口：首送达最长 ~4 分钟
    local i=0 f
    while :; do
        i=$((i+1)); [ $i -gt 60 ] && fail "300s 内下线告警未送达"
        # 只认 kill 之后送达的 service_down（bootstrap 空窗期索引为空会误报
        # 下线——实测送达早于 kill 时刻 5s，必须按 arrived_epoch > kill 过滤）。
        # 匹配逻辑全在 python 内部 try/except（半写文件/异常一律吞掉），保证
        # 命令替换退出码恒为 0——set -e 下任何子命令失败都会静默中止脚本
        f=$(python3 - "$t_kill" <<'PYEOF'
import glob, json, sys
t_kill = float(sys.argv[1])
best = None
for fp in glob.glob("tmp/webhook_*.json"):
    try:
        r = json.load(open(fp, encoding="utf-8"))
        p = r.get("payload", {})
        if p.get("search_name") == "service_down" and r.get("arrived_epoch", 0) >= t_kill:
            if best is None or r["arrived_epoch"] > json.load(open(best, encoding="utf-8"))["arrived_epoch"]:
                best = fp
    except Exception:
        continue
print(best or "")
PYEOF
)
        if [ -n "$f" ]; then
            python3 -c "
import json, sys
r = json.load(open(sys.argv[1], encoding='utf-8'))
print(f\"        下线告警送达 {r['arrived_str']}（search_name=service_down）\")" "$f"
            break
        fi
        sleep 5
    done
    local t_arrive
    t_arrive=$(python3 -c "import json,sys; print(int(json.load(open(sys.argv[1]))['arrived_epoch']))" "$f")
    local secs=$((t_arrive - t_kill))
    [ "$secs" -le 300 ] || fail "告警送达耗时 ${secs}s > 300s"
    ok "断言 B：kill → service_down 告警送达（${secs}s ≤ 300s）"
    # 重启恢复
    do_webup
    note "[ok] demo-web 已恢复（$(date '+%H:%M:%S')）"
    sleep 10
    do_traffic
    do_reconcile
    ok "断言 C：重启后对账恢复（差额 0）"
}

do_clean() {
    load_env
    step clean "全组件归零"
    pkill -f demo_web.py 2>/dev/null || true
    docker rm -f "$UF_NAME" >/dev/null 2>&1 && note "[ok] UF 容器已移除" || true
    kill_receivers
    curl -sk -u "admin:${SPLUNK_PASSWORD}" -X DELETE "$SPLD/services/data/indexes/loop_demo" >/dev/null \
        && note "[ok] 索引 loop_demo 已删除"
    docker exec -u root splunk-deploy sh -c "rm -f /opt/splunk/etc/system/local/inputs.conf; rm -rf /opt/splunk/etc/apps/lab_loop_alerts"
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "清理重启"
    rm -rf tmp
    ok "观测闭环全组件零残留"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)        do_up ;;
        webup)     do_webup ;;
        ufup)      do_ufup ;;
        traffic)   do_traffic ;;
        reconcile) do_reconcile ;;
        drill)     do_drill ;;
        clean)     do_clean ;;
        all)       do_up; do_ufup; do_webup; do_traffic; do_reconcile; do_drill; do_clean ;;
        *) echo "可用: up | ufup | webup | traffic | reconcile | drill | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
