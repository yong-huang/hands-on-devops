#!/usr/bin/env bash
# semi/10_sim_cache · 编译仿真与缓存（verilator --cc 产 C++ 模型 + RTL 哈希缓存 + 波形排除）
# 用法：./sim_cache.sh up | verify | status
#   up     推送含 sim stage 的 .gitlab-ci.yml（内容比对幂等）
#   verify 连跑两条流水线：①第二次 cache HIT 且 compile_seconds 降 ≥70% ②归档 < 10MB（波形被排除）
#   status rtl-gcd 最近流水线
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
BR="sim-cache-demo"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() {
    local attempt out
    for attempt in 1 2 3 4 5; do
        out=$(curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1")
        # 空响应与 workhorse 的 "404 page not found" 纯文本都当瞬时故障重试
        if [ -n "$out" ] && [ "$out" != "404 page not found" ]; then
            echo "$out"; return 0
        fi
        sleep 3
    done
}

ensure_ci() {
    step ci "推送含 sim stage 的 .gitlab-ci.yml + tb_main.cpp（幂等）"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08 的 ./lint_gate.sh up"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    local want cur changed=0
    want=$(cat configs/gitlab-ci.yml)
    cur=$(cat "$WORK/.gitlab-ci.yml" 2>/dev/null || echo "")
    if [ "$cur" != "$want" ]; then
        cp configs/gitlab-ci.yml "$WORK/.gitlab-ci.yml"
        git -C "$WORK" add .gitlab-ci.yml
        changed=1
    fi
    if [ ! -f "$WORK/sim/tb_main.cpp" ] || ! cmp -s configs/tb_main.cpp "$WORK/sim/tb_main.cpp"; then
        cp configs/tb_main.cpp "$WORK/sim/tb_main.cpp"
        git -C "$WORK" add sim/tb_main.cpp
        changed=1
    fi
    if [ "$changed" = 1 ]; then
        git -C "$WORK" commit -qm "ci: sim stage（verilator --cc + RTL 哈希缓存 + 波形排除）"
        git -C "$WORK" push -q origin main
        pass "sim stage 已推 main"
    else
        echo "[  =] 内容一致，跳过"
    fi
}

wait_pipeline_for_sha() {
    local pid="$1"
    local sha="$2"
    local out=""
    for poll_i in $(seq 1 40); do
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
    local pid="$1" pl="$2"
    for _ in $(seq 1 180); do   # 三 job 流水线（lint+unit+sim 含编译/缓存）实测可超 300s，给 15 分钟
        local st
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) echo "$st"; return 0;; esac
        sleep 5
    done
    echo timeout
}

run_branch_pipeline() {
    # 在 main 上空提交触发流水线（演示分支不匹配 rules 会得到 0 jobs 的 failed 流水线）
    git -C "$WORK" checkout -q main
    git -C "$WORK" pull -q origin main
    git -C "$WORK" commit -q --allow-empty -m "sim-cache: run $(date +%s)"
    git -C "$WORK" push -q origin main >/dev/null 2>&1 || true
    local pid sha out pl="" st=""
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    sha=$(git -C "$WORK" rev-parse HEAD)
    for _ in $(seq 1 40); do
        out=$(api "projects/$pid/pipelines?sha=$sha" | python3 -c "
import sys, json
ps = json.load(sys.stdin)
print(ps[0]['id'] if ps else 0)" 2>/dev/null || echo 0)
        [ "$out" != "0" ] && { pl="$out"; break; }
        sleep 6
    done
    [ -n "$pl" ] || { echo "[fail] 流水线未创建"; exit 1; }
    for _ in $(seq 1 60); do
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) break;; esac
        sleep 5
    done
    local jid
    jid=$(api "projects/$pid/pipelines/$pl/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'sim':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
    echo "$pl $st $jid"
}

do_up() {
    ensure_ci
}

do_verify() {
    local FAILED=0
    step bust "缓存键变更（改 tb_main.cpp 触碰 cache key.files）——bust 流水线即 run1（MISS+实编译）"
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    echo "// cache-bust $(date +%s)" >> "$WORK/sim/tb_main.cpp"
    git -C "$WORK" add sim/tb_main.cpp
    git -C "$WORK" commit -qm "sim-cache: bust cache key"
    git -C "$WORK" push -q origin main >/dev/null 2>&1 || true
    local pid sha1 pl1 st1 jid1
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    sha1=$(git -C "$WORK" rev-parse HEAD)
    read -r pl1 st1 <<<"$(wait_pipeline_for_sha "$pid" "$sha1")"
    st1=$(wait_pipeline_done "$pid" "$pl1")
    jid1=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/pipelines/$pl1/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'sim':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
    [ "$st1" = "success" ] || { fail "run1 pipeline=${st1}（期望 success）"; exit 1; }
    pass "run1 success（pipeline #${pl1}）"
    local meta1
    meta1=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/jobs/$jid1/artifacts/sim/sim_meta.json" | tail -1)
    echo "  [  =] run1 meta: $meta1"

    step run2 "第二条流水线（预期 cache HIT，compile_seconds≈0）"
    read -r pl2 st2 jid2 <<<"$(run_branch_pipeline)"
    [ "$st2" = "success" ] || { fail "run2 pipeline=${st2}（期望 success）"; exit 1; }
    pass "run2 success（pipeline #${pl2}）"
    local meta2
    meta2=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/jobs/$jid2/artifacts/sim/sim_meta.json" | tail -1)
    echo "  [  =] run2 meta: $meta2"

    step verify "验收① 缓存命中：compile_seconds 降 ≥70%"
    python3 - "$meta1" "$meta2" <<'PY'
import re, sys
def parse(s):
    hit = "cache_hit=true" in s
    c = int(re.search(r"compile_seconds=(\d+)", s).group(1))
    return hit, c
hit1, c1 = parse(sys.argv[1])
hit2, c2 = parse(sys.argv[2])
print(f"         run1 compile={c1}s (hit={hit1}) / run2 compile={c2}s (hit={hit2})")
assert not hit1 and c1 > 0, "run1 应为 cache MISS 并实测编译时间"
assert hit2 and c2 * 10 <= c1 * 3, f"缓存未生效或降幅不足 70%（{c1}→{c2}）"
print("  [ok]   缓存生效：run2 HIT 且编译耗时降幅 ≥70%")
PY
    [ $? -eq 0 ] || FAILED=1

    step verify "验收② artifacts 归档 < 10MB（20MB 假波形被排除）"
    local size
    size=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/jobs/$jid2" | python3 -c "
import sys, json
j = json.load(sys.stdin)
total = sum((f or {}).get('size', 0) for f in j.get('artifacts', []))
print(total)" 2>/dev/null || echo 0)
    if [ "$size" -gt 0 ] && [ "$size" -lt 10485760 ]; then
        pass "归档 $((size / 1024))KB < 10MB（wave.vcd 被 exclude）"
    else
        fail "归档大小 $size（期望 <10MB）"; FAILED=1
    fi
    git -C "$WORK" checkout -q main

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 10 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
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
