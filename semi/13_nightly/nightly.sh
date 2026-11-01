#!/usr/bin/env bash
# semi/13_nightly · 夜间回归与失败治理（schedule + flaky 识别 + 失败种子重跑）
# 用法：./nightly.sh up | verify | status
#   up     推 flaky_hunter + rerun job；建 nightly schedule（每天 02:00）
#   verify ①schedule 存在且 cron/目标正确 ②flaky_hunter 在真实历史中标出 seed7
#          ③用 FAILED_SEEDS=7 触发重跑 job → 只有 seed7 真正执行且通过
#   status schedule 与最近流水线
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
FULL="semi/ip/design/rtl-gcd"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

do_up() {
    step up "推 flaky_hunter + rerun job 到 rtl-gcd"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08 的 ./lint_gate.sh up"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    local changed=0
    if ! cmp -s configs/gitlab-ci.yml "$WORK/.gitlab-ci.yml"; then
        cp configs/gitlab-ci.yml "$WORK/.gitlab-ci.yml"
        git -C "$WORK" add .gitlab-ci.yml
        changed=1
    fi
    if [ ! -f "$WORK/tools/flaky_hunter.py" ] || ! cmp -s configs/flaky_hunter.py "$WORK/tools/flaky_hunter.py"; then
        mkdir -p "$WORK/tools"
        cp configs/flaky_hunter.py "$WORK/tools/flaky_hunter.py"
        git -C "$WORK" add tools/flaky_hunter.py
        changed=1
    fi
    if [ "$changed" = 1 ]; then
        git -C "$WORK" commit -qm "ci: 夜间失败种子重跑（FAILED_SEEDS 触发）+ flaky_hunter"
        git -C "$WORK" push -q origin main
        pass "已推 main"
    else
        echo "[  =] 内容一致，跳过"
    fi
    step schedule "建 nightly schedule（每天 02:00 跑回归矩阵，幂等）"
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    local have
    have=$(api "projects/$pid/pipeline_schedules" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s['description'] == 'nightly-seed-regression':
        print(s['id'])
        break" 2>/dev/null || true)
    if [ -n "$have" ]; then
        echo "[  =] schedule 已存在 id=$have"
    else
        api -X POST >/dev/null 2>&1 || true
        curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
            "$URL/api/v4/projects/$pid/pipeline_schedules" \
            -d "description=nightly-seed-regression" \
            -d "ref=main" \
            -d "cron=0 2 * * *" | python3 -c "import sys,json;s=json.load(sys.stdin);print('[ok] schedule id=%s cron=%s next=%s' % (s.get('id'), s.get('cron'), s.get('next_run_at')))"
    fi
}

do_verify() {
    local FAILED=0
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

    step verify "验收① nightly schedule 在位（cron 0 2 * * *，target main）"
    local sched
    sched=$(api "projects/$pid/pipeline_schedules" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    if s['description'] == 'nightly-seed-regression':
        print(s['cron'], s['ref'], s['active'])
        break")
    if echo "$sched" | grep -q "0 2" && echo "$sched" | grep -qE "(refs/heads/)?main True"; then
        pass "schedule 在位：$sched"
    else
        fail "schedule 异常：$sched"; FAILED=1
    fi

    step verify "验收② flaky_hunter 扫真实历史（146 全绿 / 148 seed7 红）"
    python3 configs/flaky_hunter.py "$URL" "$(cat "$TOKEN_FILE")" "$FULL" 25 > flaky_out.txt 2>&1 || true
    cat flaky_out.txt | sed 's/^/  /'
    if grep -q "flaky=\['7'\]" flaky_out.txt; then
        pass "flaky_hunter：seed7 被标记 flaky（时红时绿）"
    else
        fail "seed7 未被标记 flaky"; FAILED=1
    fi

    step verify "验收③ FAILED_SEEDS=7 触发重跑 → 仅 seed7 真执行且通过"
    local sha resp
    sha=$(git -C "$WORK" rev-parse HEAD)
    resp=$(curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        -H "Content-Type: application/json" \
        "$URL/api/v4/projects/$pid/pipeline" \
        -d '{"ref":"main","variables":[{"key":"NIGHTLY_RERUN","value":"true"},{"key":"FAILED_SEEDS","value":"7"}]}')
    local pl
    pl=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',0))")
    [ "$pl" != "0" ] || { fail "重跑流水线未创建"; exit 1; }
    local st
    for _ in $(seq 1 100); do
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) break;; esac
        sleep 6
    done
    local states
    states=$(api "projects/$pid/pipelines/$pl/jobs" | python3 -c "
import sys, json
d = {}
for j in json.load(sys.stdin):
    if j['name'].startswith('regression'):
        d[j['status']] = d.get(j['status'], 0) + 1
print(' '.join(f'{k}={v}' for k, v in d.items()))")
    echo "  [  =] rerun pipeline #${pl} ${st}：regression jobs ${states}"
    if [ "$st" = "success" ] && echo "$states" | grep -qE "success=1" && ! echo "$states" | grep -q "success=2"; then
        pass "仅 seed7 一个 regression job 执行且通过（其余 skipped）"
    else
        fail "重跑语义异常：${st} ${states}"; FAILED=1
    fi

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 13 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "schedule"
    api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/pipeline_schedules" | python3 -c "
import sys, json
for s in json.load(sys.stdin):
    print(f\"  #{s['id']} {s['description']} cron={s['cron']} active={s['active']} next={s.get('next_run_at')}\")"
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
