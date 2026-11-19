#!/usr/bin/env bash
# =============================================================================
# 04 · 统计管道 — 主演示脚本
#
# 三问（stats/timechart/top 各两种写法对照）+ 纯 Python 双口径对照：
# 同一份 access 日志，Splunk 与独立 Python 实现（crosscheck.py）各算一遍，
# 每小时桶 / Top10 / 404 占比（总体+逐日）误差 ≤ 1% 才算过。
#
# ./spl_stats.sh up          确保 splunk 在跑 + tutorial 数据就绪（复用 lab 02）
# ./spl_stats.sh queries     三问 × 2 写法的 SPL 输出
# ./spl_stats.sh crosscheck  预取 SPL 结果 → Python 对照 → 误差断言
# ./spl_stats.sh clean       清 tmp（查询不落盘）
# ./spl_stats.sh all         up → queries → crosscheck → clean
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPL="https://localhost:28089"
LAB01="../01_splunk_deploy"
LAB02="../02_tutorial_data"
ST="sourcetype=access_combined_wcookie"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

load_env() {
    [ -f "$LAB01/.env" ] || fail "缺 $LAB01/.env——先做 lab 01"
    # set -a：source 进来的变量全部导出——crosscheck 的 python 子进程要读环境变量
    set -a
    # shellcheck disable=SC1090
    source "$LAB01/.env"
    set +a
    [ -n "${SPLUNK_PASSWORD:-}" ] || fail "SPLUNK_PASSWORD 为空"
}

# REST oneshot 搜索（前缀规则见 lab 02/03）
spl_search() {
    local s="$1" pfx
    case "$s" in
        "|"*|tstats*|search*) pfx="" ;;
        *) pfx="search " ;;
    esac
    curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/search/jobs" \
        --data-urlencode "search=${pfx}${s}" \
        --data-urlencode "exec_mode=oneshot" \
        --data-urlencode "output_mode=json" \
        --data-urlencode "earliest_time=0"
}

# 表格化打印 oneshot 结果（键值行）
show() {  # <说明> <SPL>
    note "── $1"
    spl_search "$2" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bad = [m['text'] for m in d.get('messages', []) if m.get('type') in ('ERROR', 'FATAL')]
if bad:
    print('        ❌', bad[0][:100]); exit(1)
for r in d.get('results', []):
    kv = '  '.join(f'{k}={v}' for k, v in r.items())
    print('        ' + kv)"
    echo "=> $2" >> tmp/queries.log
}

do_up() {
    load_env
    step up "确保 splunk 在跑 + tutorial 数据就绪"
    if ! curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/server/info" 2>/dev/null | grep -q 'version'; then
        docker compose -f "$LAB01/docker-compose.yml" up -d 2>&1 | sed 's/^/        /'
        local i=0
        while :; do
            i=$((i+1)); [ $i -gt 84 ] && fail "splunk 420s 未就绪"
            curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/server/info" 2>/dev/null | grep -q 'version' \
                && { note "[ok] splunkd 就绪（约 $((i*5))s）"; break; }
            sleep 5
        done
    else
        note "[ok] splunk-deploy 已在运行"
    fi
    local total
    total=$(spl_search "index=tutorial | stats count" | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['results'][0].values())[0] if d.get('results') else 0)")
    if [ "$total" -ge 1000 ] 2>/dev/null; then
        note "[ok] tutorial 数据就绪（${total} 条）"
    else
        note "tutorial 数据不足 → 复用 lab 02 补灌"
        "$LAB02/tutorial_data.sh" download 2>&1 | sed 's/^/        /'
        "$LAB02/tutorial_data.sh" ingest  2>&1 | sed 's/^/        /'
    fi
}

do_queries() {
    load_env
    mkdir -p tmp && rm -f tmp/queries.log
    step queries "三问 × 2 写法（search 段时间裁剪已含 earliest_time=0 语义）"
    # Q1 每小时访问量趋势
    show "Q1a timechart 12h 分桶" "index=tutorial $ST | timechart span=12h count"
    show "Q1b bin+stats 同题对照" "index=tutorial $ST | bin _time span=12h | stats count by _time"
    # Q2 Top 10 访问来源
    show "Q2a top（自带 percent 列）" "index=tutorial $ST | top limit=10 clientip"
    show "Q2b sort+stats 同题对照" "index=tutorial $ST | stats count by clientip | sort -count | head 10"
    # Q3 404 占比（总体 + 随时间变化）
    show "Q3a stats 条件聚合算占比" "index=tutorial $ST | stats count as total, count(eval(status=404)) as nf | eval pct=round(nf/total*100,4)"
    show "Q3b eval+sum 同题对照" "index=tutorial $ST | eval is404=if(status=404,1,0) | stats sum(is404) as nf, count as total | eval pct=round(nf/total*100,4)"
    show "Q3c 404 占比逐日趋势" "index=tutorial $ST | timechart span=1d count(eval(status=404)) as nf, count as total | eval pct=round(nf/total*100,2)"
    ok "三问 7 条 SPL 全部执行（明细见上）"
}

do_crosscheck() {
    load_env
    step crosscheck "双口径对照：SPL vs 纯 Python（容差 1%）"
    mkdir -p tmp
    # Python 端要原始文件：zip 缺失就复用 lab 02 下载，解包到本实验 tmp
    local zip="$LAB02/tutorialdata.zip"; [ -f "$zip" ] || zip="$LAB02/tmp/tutorialdata.zip"
    [ -f "$zip" ] || "$LAB02/tutorial_data.sh" download >/dev/null 2>&1 || true
    [ -f "$LAB02/tmp/tutorialdata.zip" ] && zip="$LAB02/tmp/tutorialdata.zip"
    [ -f "$zip" ] || fail "找不到教程 zip——先跑 lab 02 download"
    rm -rf tmp/tut && mkdir -p tmp/tut
    unzip -qo "$zip" -d tmp/tut
    note "[ok] 原始文件解包到 tmp/tut（Python 端数据源）"
    # Splunk 端：预取四条对照查询的原始结果
    python3 - "$zip" <<'PYEOF'
import json, subprocess, sys
q = {
  "q1":  "index=tutorial sourcetype=access_combined_wcookie | timechart span=12h count",
  "q2":  "index=tutorial sourcetype=access_combined_wcookie | top limit=10 clientip",
  "q3":  "index=tutorial sourcetype=access_combined_wcookie | stats count as total, count(eval(status=404)) as nf | eval pct=round(nf/total*100,4)",
  "q3c": "index=tutorial sourcetype=access_combined_wcookie | timechart span=1d count(eval(status=404)) as nf, count as total | eval pct=round(nf/total*100,2)",
}
out = {}
for k, spl in q.items():
    r = subprocess.run(["curl", "-sk", "-u", f"admin:{__import__('os').environ['SPLUNK_PASSWORD']}",
                        "https://localhost:28089/services/search/jobs",
                        "--data-urlencode", f"search=search {spl}",
                        "--data-urlencode", "exec_mode=oneshot",
                        "--data-urlencode", "output_mode=json",
                        "--data-urlencode", "earliest_time=0"],
                       capture_output=True, text=True, check=True)
    out[k] = json.loads(r.stdout)
json.dump(out, open("tmp/spl_raw.json", "w"), ensure_ascii=False)
print("        [ok] SPL 端四条查询已预取")
PYEOF
    python3 crosscheck.py --raw tmp/spl_raw.json --files tmp/tut \
        && ok "双口径对照全过（≤1%）" \
        || fail "双口径对照超差（明细见上）"
}

do_clean() {
    step clean "清 tmp"
    rm -rf tmp
    ok "tmp 已清；查询不落盘，教程数据归 lab 02 管"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)         do_up ;;
        queries)    do_queries ;;
        crosscheck) do_crosscheck ;;
        clean)      do_clean ;;
        all)        do_up; do_queries; do_crosscheck; do_clean ;;
        *) echo "可用: up | queries | crosscheck | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
