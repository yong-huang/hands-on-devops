#!/usr/bin/env bash
# semi/20_full_chain · ⛓️ 集成点③：commit → Release 全链手动演练与断点验证
# 用法：./full_chain.sh up | verify | status
#   up     推全链终装 yml（全 DAG：MR 段 + tag 段 + needs 全声明）+ 演练报告骨架
#   verify ①全链一次全绿且各 stage 耗时在报告 ②人为注错让回归红 → 下游（fpga/release）全未执行
#   status rtl-gcd 最近流水线与 stage 耗时
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
FULL="semi/ip/design/rtl-gcd"
BR="fullchain-demo"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() {
    local attempt out
    for attempt in 1 2 3 4 5; do
        out=$(curl -s --max-time 30 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1")
        if [ -n "$out" ] && [ "$out" != "404 page not found" ]; then
            echo "$out"; return 0
        fi
        sleep 3
    done
}

wait_pipeline_for_sha() {
    local pid="$1"
    local sha="$2"
    local out=""
    for _ in $(seq 1 60); do
        out=$(api "projects/$pid/pipelines?sha=$sha" | python3 -c "
import sys, json
ps = json.load(sys.stdin)
if ps:
    print(ps[0]['id'], ps[0]['status'])
else:
    print('0 none')" 2>/dev/null || echo "0 none")
        read -r pl status <<<"$out"
        [ "${pl:-0}" != "0" ] && { echo "$pl $status"; return 0; }
        sleep 6
    done
    echo "0 none"
}

wait_pipeline_done() {
    local pid="$1"
    local pl="$2"
    for _ in $(seq 1 240); do
        local st
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) echo "$st"; return 0;; esac
        sleep 5
    done
    echo timeout
}

do_up() {
    step up "推全链终装 yml（MR 段 + tag 段，needs 全声明）"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    # rtl-gcd 的 yml 已由 08-19 逐段生长为全链（各 stage 齐备）；本实验只补演练报告骨架
    mkdir -p "$WORK/docs"
    if [ ! -f "$WORK/docs/full_chain_report.md" ]; then
        cat > "$WORK/docs/full_chain_report.md" <<'MD'
# 全链演练报告（⛓️ 集成点③）

| 轮次 | 结果 | 各阶段耗时 | 断点记录 |
|:---|:---|:---|:---|
MD
        git -C "$WORK" add docs/full_chain_report.md
        git -C "$WORK" commit -qm "docs: 全链演练报告骨架"
        git -C "$WORK" push -q origin main
    fi
    pass "演练报告骨架就绪（docs/full_chain_report.md）"
}

# 在演示分支注入/修复指定级错误，并触发 MR 流水线
run_demo() {
    local kind="$1"   # green | regression
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    git -C "$WORK" branch -D "$BR" >/dev/null 2>&1 || true
    git -C "$WORK" push -q origin --delete "$BR" >/dev/null 2>&1 || true
    git -C "$WORK" checkout -qb "$BR"
    if [ "$kind" = "regression" ]; then
        python3 - "$WORK" <<'PY'
import sys
f = sys.argv[1] + "/tb/tb_random.py"
s = open(f).read()
s = s.replace("        got = await gcd_op(dut, a, b)",
              "        if seed == 3 and i == 4:\n            want += 1\n        got = await gcd_op(dut, a, b)")
open(f, "w").write(s)
PY
    fi
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "demo: fullchain $kind" --allow-empty
    git -C "$WORK" push -q origin "$BR" >/dev/null 2>&1 || true
    local pid resp mr_iid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    resp=$(curl -s --max-time 20 -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/merge_requests" \
        -d "source_branch=$BR" -d "target_branch=main" -d "title=demo: fullchain $kind")
    mr_iid=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('iid',''))" 2>/dev/null || true)
    local sha
    sha=$(git -C "$WORK" rev-parse HEAD)
    echo "$pid $mr_iid $sha"
}

do_verify() {
    local FAILED=0
    local pid mr sha pl st
    step demo1 "全绿轮：lint→unit→回归→fpga→制品 全链一次绿"
    local raw1
    raw1=$(run_demo green)
    echo "  [  =] run_demo 输出：$(echo "$raw1" | tail -1)"
    local pid mr sha
    pid=$(echo "$raw1" | tail -1 | awk '{print $1}')
    mr=$(echo "$raw1" | tail -1 | awk '{print $2}')
    sha=$(echo "$raw1" | tail -1 | awk '{print $3}')
    read -r pl st <<<"$(wait_pipeline_for_sha "$pid" "$sha")"
    st=$(wait_pipeline_done "$pid" "$pl")
    if [ "$st" = "success" ]; then
        pass "全绿轮流水线 success（#${pl}）"
    else
        fail "全绿轮 ${st}（期望 success）"; FAILED=1
    fi
    # 采集各 job 耗时入报告
    local durations
    durations=$(api "projects/$pid/pipelines/$pl/jobs" | python3 -c "
import sys, json
try:
    for j in sorted(json.load(sys.stdin), key=lambda x: x['id']):
        if j['status'] in ('success', 'failed') and not j['name'].startswith('regression'):
            print(f\"| {j['name']} | {j['status']} | {j['duration'] or 0:.0f}s |\")
except Exception:
    pass")
    {
        echo ""
        echo "## 全绿轮（pipeline #${pl}）"
        echo ""
        echo "| job | 状态 | 耗时 |"
        echo "|:---|:---|:---|"
        echo "$durations"
    } >> "$WORK/docs/full_chain_report.md"
    git -C "$WORK" add docs/full_chain_report.md && git -C "$WORK" commit -qm "docs: 演练报告-全绿轮" && git -C "$WORK" push -q origin main

    step demo2 "回归注错轮：regression 红 → fpga（needs）不执行"
    local raw2
    raw2=$(run_demo regression)
    pid=$(echo "$raw2" | tail -1 | awk '{print $1}')
    sha=$(echo "$raw2" | tail -1 | awk '{print $3}')
    read -r pl st <<<"$(wait_pipeline_for_sha "$pid" "$sha")"
    st=$(wait_pipeline_done "$pid" "$pl")
    local states
    states=$(api "projects/$pid/pipelines/$pl/jobs" | python3 -c "
import sys, json
d = {}
for j in json.load(sys.stdin):
    d.setdefault(j['name'], j['status'])
    if j['name'] == 'regression: [3]' or (j['name'] == 'fpga'):
        d[j['name']] = j['status']
print(' '.join(f'{k}={v}' for k, v in d.items()))")
    echo "  [  =] 注错轮 #$pl ${st}：$states"
    if [ "$st" = "failed" ] &&
       echo "$states" | grep -qE "regression: \[3\]=failed" &&
       echo "$states" | grep -qE "fpga=(canceled|skipped)"; then
        pass "regression 红、fpga 因 needs 未执行（断点阻断生效）"
    else
        fail "断点阻断异常：$st $states"; FAILED=1
    fi
    {
        echo ""
        echo "## 注错轮（pipeline #${pl}）：regression: [3] 红 → fpga skipped（needs 阻断）"
    } >> "$WORK/docs/full_chain_report.md"
    git -C "$WORK" add docs/full_chain_report.md && git -C "$WORK" commit -qm "docs: 演练报告-注错轮" && git -C "$WORK" push -q origin main
    git -C "$WORK" checkout -q main

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 20 全部验收断言通过（演练报告见 rtl-gcd/docs/full_chain_report.md）" ||
        { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "rtl-gcd 最近流水线"
    api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/pipelines?per_page=3" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(f\"  #{p['iid']} {p['status']} {p['ref']}\")"
}

main() {
    local target="${1:-up}"
    case "${target}" in
        up)     do_up ;;
        verify) do_verify ;;
        status) do_status ;;
        *) echo "用法: $0 up | verify | status" >&2; exit 1 ;;
    esac
}
main "$@"
