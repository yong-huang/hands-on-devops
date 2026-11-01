#!/usr/bin/env bash
# semi/12_seed_matrix · 种子回归矩阵（16 路 parallel:matrix + 聚合器）
# 用法：./seed_matrix.sh up | verify | status
#   up     推 regression/aggregate stage + tb_random.py + runner/聚合器到 rtl-gcd
#   verify 全绿基线（pass=16 fail=0）→ 植入 seed7 必败 → 聚合报 15/16 且失败清单含 7 → 修复
#   status 最近流水线
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
FULL="semi/ip/design/rtl-gcd"
BR="seed-matrix-demo"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

wait_pipeline_for_sha() {
    local pid="$1"
    local sha="$2"
    local out=""
    for _ in $(seq 1 40); do
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
    for _ in $(seq 1 240); do   # 16 子 job × runner 并发 2 → 最长可到 20 分钟
        local st
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) echo "$st"; return 0;; esac
        sleep 5
    done
    echo timeout
}

do_up() {
    step up "推 regression 矩阵 + tb_random.py + runner/聚合器到 rtl-gcd"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08 的 ./lint_gate.sh up"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    local changed=0
    if ! cmp -s configs/gitlab-ci.yml "$WORK/.gitlab-ci.yml"; then
        cp configs/gitlab-ci.yml "$WORK/.gitlab-ci.yml"
        git -C "$WORK" add .gitlab-ci.yml
        changed=1
    fi
    for pair in "tb_random.py:tb/tb_random.py" "run_regression.py:sim/run_regression.py" "aggregate_results.py:tools/aggregate_results.py"; do
        local src="${pair%%:*}" dst="${pair##*:}"
        if [ ! -f "$WORK/$dst" ] || ! cmp -s "configs/$src" "$WORK/$dst"; then
            mkdir -p "$WORK/$(dirname "$dst")"
            cp "configs/$src" "$WORK/$dst"
            git -C "$WORK" add "$dst"
            changed=1
        fi
    done
    if [ "$changed" = 1 ]; then
        git -C "$WORK" commit -qm "ci: 种子回归矩阵（parallel:matrix 16 seeds + 聚合器）"
        git -C "$WORK" push -q origin main
        pass "regression 矩阵已推 main"
    else
        echo "[  =] 内容一致，跳过"
    fi
}

open_mr() {
    local title="$1"
    git -C "$WORK" checkout -q main
    git -C "$WORK" branch -D "$BR" >/dev/null 2>&1 || true
    git -C "$WORK" push -q origin --delete "$BR" >/dev/null 2>&1 || true
    git -C "$WORK" checkout -qb "$BR"
    if [ "$title" = "bug" ]; then
        python3 - "$WORK" <<'PY'
import sys
f = sys.argv[1] + "/tb/tb_random.py"
s = open(f).read()
s = s.replace("        got = await gcd_op(dut, a, b)",
              "        if seed == 7 and i == 4:\n            want += 1\n        got = await gcd_op(dut, a, b)")
open(f, "w").write(s)
PY
    fi
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "demo: $title"
    git -C "$WORK" push -q origin "$BR" >/dev/null 2>&1 || true
    local pid resp new_iid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    resp=$(curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/merge_requests" \
        -d "source_branch=$BR" -d "target_branch=main" -d "title=demo: $title")
    new_iid=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('iid',''))" 2>/dev/null || true)
    echo "$pid $new_iid"
}

fetch_aggregate() {
    # 从聚合 job 归档取 summary.json 内容
    local pid="$1" pl="$2"
    local jid
    jid=$(api "projects/$pid/pipelines/$pl/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'aggregate':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
    [ -n "$jid" ] || { echo ""; return; }
    api "projects/$pid/jobs/$jid/artifacts/sim/summary.json"
}

do_verify() {
    local FAILED=0
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

    step demo1 "全绿基线：16 子 job + 聚合 pass=16 fail=0"
    read -r pid mr_iid <<<"$(open_mr baseline)"
    git -C "$WORK" commit -q --allow-empty -m "demo: 触发矩阵" && git -C "$WORK" push -q origin "$BR" >/dev/null 2>&1 || true
    local sha pl st
    sha=$(git -C "$WORK" rev-parse HEAD)
    read -r pl st <<<"$(wait_pipeline_for_sha "$pid" "$sha")"
    st=$(wait_pipeline_done "$pid" "$pl")
    if [ "$st" = "success" ]; then
        pass "全绿基线流水线 success（#$pl）"
    else
        fail "基线 pipeline=$st（期望 success）"; FAILED=1
    fi
    local summary
    summary=$(fetch_aggregate "$pid" "$pl")
    if echo "$summary" | grep -q '"passed": 16'; then
        pass "聚合器：$(echo "$summary" | tr -d '\n ' | head -c 120)"
    else
        fail "聚合 summary 异常：${summary:0:150}"; FAILED=1
    fi

    step demo2 "植入 seed=7 必败 → 聚合 15/16 且失败清单含 7"
    read -r pid mr2 <<<"$(open_mr bug)"
    git -C "$WORK" commit -q --allow-empty -m "demo: 触发矩阵（bug）" && git -C "$WORK" push -q origin "$BR" >/dev/null 2>&1 || true
    sha=$(git -C "$WORK" rev-parse HEAD)
    read -r pl st <<<"$(wait_pipeline_for_sha "$pid" "$sha")"
    st=$(wait_pipeline_done "$pid" "$pl")
    [ "$st" = "failed" ] && pass "注错流水线 failed（#$pl）" || { fail "pipeline=$st"; FAILED=1; }
    summary=$(fetch_aggregate "$pid" "$pl")
    if echo "$summary" | grep -q '"passed": 15' && echo "$summary" | grep -q '"seed": "7"'; then
        pass "聚合器：15/16，失败清单精确含 seed 7"
    else
        fail "聚合 summary 异常：${summary:0:200}"; FAILED=1
    fi
    git -C "$WORK" checkout -q main

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 12 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
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
