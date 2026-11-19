#!/usr/bin/env bash
# =============================================================================
# 06 · lookup 数据富化 — 主演示脚本
#
# 三张字典（状态码语义 / UA 设备分类(WILDCARD) / 服务器资产）部署进 Splunk，
# 富化 39,532 条 access 事件并做四条断言；同题 join vs lookup 计时对照。
#
# ./spl_lookup.sh up        确保 splunk + tutorial 数据就绪（复用 lab 02）
# ./spl_lookup.sh deploy    3 张 CSV 进 lookups 目录 + transforms.conf + 重启
# ./spl_lookup.sh enrich    富化断言（null 率 ≤1% / 行数一致 / outputlookup 回读）
# ./spl_lookup.sh perf      join vs lookup 同题计时（各 3 轮取中位）
# ./spl_lookup.sh clean     删字典与配置 + 重启归零
# ./spl_lookup.sh all       up → deploy → enrich → perf → clean
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
    set -a; # shellcheck disable=SC1090
    source "$LAB01/.env"; set +a
    [ -n "${SPLUNK_PASSWORD:-}" ] || fail "SPLUNK_PASSWORD 为空"
}

spl_search() {  # <SPL> [输出文件] → 结果 JSON（stdout 或落盘）
    local s="$1" pfx out="${2:-}"
    case "$s" in
        "|"*|tstats*|search*) pfx="" ;;
        *) pfx="search " ;;
    esac
    if [ -n "$out" ]; then
        curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/search/jobs" \
            --data-urlencode "search=${pfx}${s}" \
            --data-urlencode "exec_mode=oneshot" \
            --data-urlencode "output_mode=json" \
            --data-urlencode "earliest_time=0" -o "$out"
    else
        curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/search/jobs" \
            --data-urlencode "search=${pfx}${s}" \
            --data-urlencode "exec_mode=oneshot" \
            --data-urlencode "output_mode=json" \
            --data-urlencode "earliest_time=0"
    fi
}

qcount() { spl_search "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['results'][0].values())[0] if d.get('results') else 0)"; }

# 新增 lookup 文件/配置后 Splunk 的生效是异步的（lookups 目录延迟扫描）——
# 首查可能报错，轮询到成功为止（实测踩过：docker cp 后立查直接 KeyError）
retry_val() {  # <SPL> → 首行首列值（≤60s 重试）
    local i=0 v
    while :; do
        i=$((i+1)); [ $i -gt 12 ] && { echo ""; return 1; }
        v=$(spl_search "$1" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['results'][0].values())[0] if d.get('results') else '')" 2>/dev/null) || v=""
        [ -n "$v" ] && { echo "$v"; return 0; }
        sleep 5
    done
}

wait_splunk() {
    local tag="$1" i=0
    note "等待 splunkd 就绪（${tag}）..."
    while :; do
        i=$((i+1)); [ $i -gt 84 ] && fail "$tag 420s 未就绪"
        curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/server/info" 2>/dev/null | grep -q 'version' \
            && { note "[ok] 就绪（约 $((i*5))s）"; return 0; }
        sleep 5
    done
}

do_up() {
    load_env
    step up "确保 splunk 在跑 + tutorial 数据就绪"
    if ! curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/server/info" 2>/dev/null | grep -q 'version'; then
        docker compose -f "$LAB01/docker-compose.yml" up -d 2>&1 | sed 's/^/        /'
        wait_splunk "冷启动"
    else
        note "[ok] splunk-deploy 已在运行"
    fi
    local total
    total=$(qcount "index=tutorial | stats count")
    if [ "$total" -ge 1000 ] 2>/dev/null; then
        note "[ok] tutorial 数据就绪（${total} 条）"
    else
        note "tutorial 数据不足 → 复用 lab 02 补灌"
        "$LAB02/tutorial_data.sh" download 2>&1 | sed 's/^/        /'
        "$LAB02/tutorial_data.sh" ingest  2>&1 | sed 's/^/        /'
    fi
}

do_deploy() {
    load_env
    step deploy "3 张 CSV 进 lookups 目录 + transforms.conf + 重启生效"
    for f in http_status.csv ua_class.csv servers.csv; do
        docker cp "configs/csv/$f" "splunk-deploy:/opt/splunk/etc/system/lookups/$f"
    done
    docker cp configs/transforms.conf splunk-deploy:/opt/splunk/etc/system/local/transforms.conf
    note "[ok] 3 张 CSV + transforms.conf 已进容器"
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "配置生效重启"
}

do_enrich() {
    load_env
    step enrich "富化四断言"
    mkdir -p tmp
    # 断言 1：status_desc null 率 ≤1%（并列出未命中码，若有）
    local nulls total
    total=$(qcount "index=tutorial $ST | stats count")
    nulls=$(qcount "index=tutorial $ST | lookup http_status status OUTPUT status_desc | where isnull(status_desc) | stats count")
    local pct
    pct=$(python3 -c "print(round(${nulls:-0}/${total}*100,4))")
    [ "$(python3 -c "print(1 if ${pct:-100} <= 1 else 0)")" = "1" ] || fail "断言1 null 率 ${pct}% > 1%"
    ok "断言1：status_desc null 率 ${nulls}/${total} = ${pct}%（≤1%）"
    if [ "$nulls" != "0" ]; then
        note "   未命中的状态码："
        spl_search "index=tutorial $ST | lookup http_status status OUTPUT status_desc | where isnull(status_desc) | stats count by status" \
            | python3 -c "
import json,sys
for r in json.load(sys.stdin).get('results', []): print('        status=' + r['status'])"
    fi
    # 断言 2：ua_class WILDCARD 富化 null 率 = 0
    local ua_nulls
    ua_nulls=$(qcount "index=tutorial $ST | lookup ua_class useragent AS ua_prefix OUTPUT device_class | where isnull(device_class) | stats count")
    [ "$ua_nulls" = "0" ] || fail "断言2 UA 富化 null=${ua_nulls}（WILDCARD 字典漏配）"
    ok "断言2：UA 设备分类 null = 0（26 种 UA 全命中 WILDCARD 字典）"
    # 断言 3：servers 资产映射覆盖全部 5 台 host
    local host_nulls
    host_nulls=$(qcount "index=tutorial | lookup servers host OUTPUT env | where isnull(env) | stats count")
    [ "$host_nulls" = "0" ] || fail "断言3 资产映射 null=${host_nulls}"
    ok "断言3：servers 资产映射覆盖全部 host（null=0）"
    # 断言 4：inputlookup 行数与 CSV 文件行数一致 + outputlookup 回读
    python3 - <<'PYEOF'
import json, subprocess, os

def q(spl):
    # inputlookup 等生成型命令不能加 search 前缀（lab 02 规则）
    s = spl if spl.startswith("|") else "search " + spl
    r = subprocess.run(["curl", "-sk", "-u", f"admin:{os.environ['SPLUNK_PASSWORD']}",
                        "https://localhost:28089/services/search/jobs",
                        "--data-urlencode", f"search={s}",
                        "--data-urlencode", "exec_mode=oneshot",
                        "--data-urlencode", "output_mode=json",
                        "--data-urlencode", "earliest_time=0"],
                       capture_output=True, text=True, check=True)
    return len(json.loads(r.stdout).get("results", []))

ok = True
for name in ("http_status", "ua_class", "servers"):
    csv_rows = sum(1 for line in open(f"configs/csv/{name}.csv", encoding="utf-8")) - 1
    lookup_rows = q(f"| inputlookup {name}.csv")
    mark = "✅" if csv_rows == lookup_rows else "❌"
    print(f"        {mark} {name}: CSV {csv_rows} 行 vs inputlookup {lookup_rows} 行")
    ok = ok and csv_rows == lookup_rows
# outputlookup：把 Top20 来源写回字典并回读
q("index=tutorial sourcetype=access_combined_wcookie | top limit=20 clientip | outputlookup top_clients.csv")
back = q("| inputlookup top_clients.csv")
print(f"        {'✅' if back == 20 else '❌'} outputlookup top_clients.csv 写入并回读 {back} 行")
assert ok and back == 20
PYEOF
    ok "断言4：inputlookup 行数一致 + outputlookup 回读一致"
}

do_perf() {
    load_env
    step perf "同题富化：join vs lookup 计时（各 3 轮取中位）"
    # 同题：给每条事件标注"该状态码的事件总数"。
    # join 版：子搜索每次全量扫描+聚合（真实代价所在）
    # lookup 版：读预聚合字典（outputlookup 一次性生成，即 summary index 思路）
    # 注意别写 "| index=..."——index 是 search 词不是生成型命令，管道开头非法
    # 字典落位：system 级 lookup 定义只从 system/lookups/ 解析文件，而 REST 搜索
    # 的 outputlookup 写进 apps/search/lookups/（应用上下文）——因此本地生成后
    # docker cp 进 system/lookups，与另外三张字典同款部署路径
    mkdir -p tmp
    spl_search "index=tutorial sourcetype=access_combined_wcookie | stats count as status_count by status" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d.get('results', [])
with open('tmp/status_counts.csv', 'w', encoding='utf-8') as f:
    f.write('status,status_count\n')
    for r in rows:
        f.write(f\"{r['status']},{r['status_count']}\n\")
print(f'        [ok] 预聚合字典本地生成 {len(rows)} 行')"
    docker cp tmp/status_counts.csv splunk-deploy:/opt/splunk/etc/system/lookups/status_counts.csv
    local gen_rows
    gen_rows=$(qcount "| inputlookup status_counts.csv | stats count")
    [ "$gen_rows" = "9" ] || fail "预聚合字典异常：inputlookup ${gen_rows} 行（期望 9）"
    note "[ok] 字典已进 system/lookups 并回读（9 行）"
    local lookup_spl='index=tutorial sourcetype=access_combined_wcookie | lookup status_counts status OUTPUT status_count | stats max(status_count) as m'
    # REST 的"不补隐式 search"规则连子搜索也覆盖——[] 内必须写 search 前缀
    local join_spl='index=tutorial sourcetype=access_combined_wcookie | join type=left status [search index=tutorial sourcetype=access_combined_wcookie | stats count as status_count by status] | stats max(status_count) as m'
    local lk out
    lk=$(retry_val "$lookup_spl") || fail "lookup 版查询 60s 未成功（lookups 目录异步生效延迟）"
    out=$(retry_val "$join_spl") || fail "join 版查询 60s 未成功"
    [ "$lk" = "$out" ] || fail "两种写法结果不同：lookup=${lk} join=${out}"
    note "结果一致（max(status_count)=${lk}）——公平计时"
    local lk_t jn_t
    # 计时：python 统一口径（3 轮取中位，含 curl 往返）
    lk_t=$(python3 - "$lookup_spl" <<'PYEOF'
import os, statistics, subprocess, sys, time
spl = sys.argv[1]
ts = []
for _ in range(3):
    t0 = time.perf_counter()
    subprocess.run(["curl", "-sk", "-u", f"admin:{os.environ['SPLUNK_PASSWORD']}",
                    "https://localhost:28089/services/search/jobs",
                    "--data-urlencode", f"search=search {spl}",
                    "--data-urlencode", "exec_mode=oneshot",
                    "--data-urlencode", "output_mode=json",
                    "--data-urlencode", "earliest_time=0"], check=True, capture_output=True)
    ts.append(time.perf_counter() - t0)
print(f"{statistics.median(ts):.2f}")
PYEOF
)
    jn_t=$(python3 - "$join_spl" <<'PYEOF'
import os, statistics, subprocess, sys, time
spl = sys.argv[1]
ts = []
for _ in range(3):
    t0 = time.perf_counter()
    subprocess.run(["curl", "-sk", "-u", f"admin:{os.environ['SPLUNK_PASSWORD']}",
                    "https://localhost:28089/services/search/jobs",
                    "--data-urlencode", f"search=search {spl}",
                    "--data-urlencode", "exec_mode=oneshot",
                    "--data-urlencode", "output_mode=json",
                    "--data-urlencode", "earliest_time=0"], check=True, capture_output=True)
    ts.append(time.perf_counter() - t0)
print(f"{statistics.median(ts):.2f}")
PYEOF
)
    note "lookup 中位耗时 ${lk_t}s | join 中位耗时 ${jn_t}s"
    python3 -c "
ratio = ${jn_t} / ${lk_t}
verdict = '✅ ≥2x' if ratio >= 2 else '⚠️ 未达 2x，实测值如实记录'
print(f'        lookup 快 {round(ratio,1)}x（{verdict}）')"
}

do_clean() {
    load_env
    step clean "删字典 + 删配置 + 重启归零"
    docker exec -u root splunk-deploy sh -c "rm -f /opt/splunk/etc/system/lookups/http_status.csv /opt/splunk/etc/system/lookups/ua_class.csv /opt/splunk/etc/system/lookups/servers.csv /opt/splunk/etc/system/lookups/status_counts.csv /opt/splunk/etc/system/local/transforms.conf /opt/splunk/etc/apps/search/lookups/top_clients.csv /opt/splunk/etc/apps/search/lookups/status_counts.csv"
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "清理重启"
    rm -rf tmp
    ok "字典、配置零残留（出厂解析不受影响）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)      do_up ;;
        deploy)  do_deploy ;;
        enrich)  do_enrich ;;
        perf)    do_perf ;;
        clean)   do_clean ;;
        all)     do_up; do_deploy; do_enrich; do_perf; do_clean ;;
        *) echo "可用: up | deploy | enrich | perf | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
