#!/usr/bin/env bash
# =============================================================================
# 03 · SPL 首搜 — 主演示脚本
#
# spl_cheatsheet.md 是唯一事实源：本脚本从卡片提取全部 SPL（```spl 围栏），
# 经 REST /services/search/jobs 逐条执行（oneshot 模式），断言 0 报错。
# 卡片改一条，验收跟着变——不需要维护两份清单。
#
# ./spl_run.sh up     确保 splunk 在跑 + tutorial 数据就绪（不足则复用 lab 02 补灌）
# ./spl_run.sh run    提取 → 逐条执行 → 断言（≥12 条、eval+where 组合 ≥2、0 报错）
# ./spl_run.sh clean  清 tmp（oneshot 任务不落盘，REST 侧无残留可断言）
# ./spl_run.sh all    up → run → clean
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPL="https://localhost:28089"
LAB01="../01_splunk_deploy"
LAB02="../02_tutorial_data"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

load_env() {
    [ -f "$LAB01/.env" ] || fail "缺 $LAB01/.env——先做 lab 01"
    # shellcheck disable=SC1090
    source "$LAB01/.env"
    [ -n "${SPLUNK_PASSWORD:-}" ] || fail "SPLUNK_PASSWORD 为空"
}

# REST oneshot 搜索（前缀规则见 lab 02：按首字符判断是否补 search）
spl_search() {  # <SPL> → 结果 JSON
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
    # 教程数据是本实验的搜索对象：不足 1000 条就复用 lab 02 的 download+ingest 补灌
    local total
    total=$(spl_search "index=tutorial | stats count" | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['results'][0].values())[0] if d.get('results') else 0)")
    if [ "$total" -ge 1000 ] 2>/dev/null; then
        note "[ok] tutorial 数据就绪（${total} 条）"
    else
        note "tutorial 数据不足（${total:-0} 条）→ 复用 lab 02 补灌"
        # 直接透传 02 的输出（勿用 grep 过滤：无匹配时 grep 退出码 1 会在
        # pipefail 下静默中止本脚本——实测踩过）；失败仍会经 pipefail 上抛
        "$LAB02/tutorial_data.sh" download 2>&1 | sed 's/^/        /'
        "$LAB02/tutorial_data.sh" ingest  2>&1 | sed 's/^/        /'
    fi
}

do_run() {
    load_env
    step run "从速查卡提取 SPL → REST 逐条执行 → 断言"
    mkdir -p tmp
    # 提取：### 标题 + 紧随的 ```spl 围栏；剥 # 注释行与空行，多行拼一行
    python3 - <<'PYEOF' > tmp/spl_list.json
import json, re

entries, title, buf, in_fence = [], None, [], False
for line in open("spl_cheatsheet.md", encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("```spl"):
        in_fence, buf, title_prev = True, [], title
        continue
    if in_fence and line.startswith("```"):
        in_fence = False
        spl = " ".join(l.strip() for l in buf if l.strip() and not l.strip().startswith("#"))
        if spl:
            entries.append({"title": title_prev or "?", "spl": spl})
        continue
    if in_fence and not line.strip().startswith("#"):
        buf.append(line)
        continue
    if line.startswith("### "):
        title = line[4:].strip()
print(json.dumps(entries, ensure_ascii=False))
PYEOF
    local n; n=$(python3 -c "import json; print(len(json.load(open('tmp/spl_list.json'))))")
    [ "$n" -ge 12 ] || fail "速查卡只有 ${n} 条 SPL，验收要求 ≥12"
    ok "提取 ${n} 条 SPL（≥12）"
    local combo; combo=$(python3 -c "
import json
es = json.load(open('tmp/spl_list.json'))
print(sum(1 for e in es if 'eval' in e['spl'] and 'where' in e['spl']))")
    [ "$combo" -ge 2 ] || fail "eval+where 组合只有 ${combo} 条，验收要求 ≥2"
    ok "eval+where 组合 ${combo} 条（≥2）"
    # 逐条执行：报 ERROR/FATAL 即 FAIL；否则记 PASS 并显示返回行数
    local pass=0 i=0 total
    total=$n
    while IFS= read -r entry; do
        i=$((i+1))
        local title spl verdict result
        title=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['title'])" "$entry")
        spl=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['spl'])" "$entry")
        result=$(spl_search "$spl")
        verdict=$(printf '%s' "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bad = [m['text'] for m in d.get('messages', []) if m.get('type') in ('ERROR', 'FATAL')]
if bad:
    print('FAIL|' + bad[0][:80])
else:
    rows = len(d.get('results', []))
    print('PASS|' + str(rows) + ' 行')")
        if [[ "$verdict" == PASS* ]]; then
            pass=$((pass+1))
            note "[${i}/${total}] ✅ ${title} —— ${verdict#PASS|}"
        else
            fail "[${i}/${total}] ${title} —— ${verdict#FAIL|}（SPL: ${spl}）"
        fi
    done < <(python3 -c "
import json
for e in json.load(open('tmp/spl_list.json')):
    print(json.dumps(e, ensure_ascii=False))")
    [ "$pass" -eq "$total" ] || fail "只有 ${pass}/${total} 条通过"
    ok "全部 ${pass}/${total} 条 SPL 执行 0 报错"
}

do_clean() {
    load_env
    step clean "清 tmp + 零残留说明"
    rm -rf tmp
    ok "tmp 已清；oneshot 搜索任务不落盘（仅任务历史，数分钟后自动过期）"
    note "教程数据归 lab 02 管，本实验不删——要清数据去 lab 02 跑 clean"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)    do_up ;;
        run)   do_run ;;
        clean) do_clean ;;
        all)   do_up; do_run; do_clean ;;
        *) echo "可用: up | run | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
