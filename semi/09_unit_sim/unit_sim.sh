#!/usr/bin/env bash
# semi/09_unit_sim · 单元仿真流水线（cocotb + JUnit 上 MR 测试 Tab）
# 用法：./unit_sim.sh up | verify | status
#   up     推送含 unit stage 的 .gitlab-ci.yml 到 rtl-gcd（内容比对幂等）
#   verify 注错（tb 期望值翻转）→ unit 红 + JUnit failure → 修复 → 绿 + junit tests=1 failures=0
#   status rtl-gcd 最近流水线
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"     # 复用 08 的规范克隆（同一个仓库）
FULL="semi/ip/design/rtl-gcd"
BR="unit-demo-bug"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

ensure_ci() {
    step ci "推送含 unit stage 的 .gitlab-ci.yml（内容比对幂等）"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08 的 ./lint_gate.sh up（规范克隆）"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    local want cur
    want=$(cat configs/gitlab-ci.yml)
    cur=$(cat "$WORK/.gitlab-ci.yml" 2>/dev/null || echo "")
    if [ "$cur" = "$want" ]; then
        echo "[  =] .gitlab-ci.yml 内容一致，跳过"
    else
        cp configs/gitlab-ci.yml "$WORK/.gitlab-ci.yml"
        git -C "$WORK" add -A
        git -C "$WORK" commit -qm "ci: unit stage（cocotb + iverilog，JUnit 上 MR 测试 Tab）"
        git -C "$WORK" push -q origin main
        pass ".gitlab-ci.yml 已更新"
    fi
}

open_bug_mr() {
    git -C "$WORK" checkout -q main
    git -C "$WORK" branch -D "$BR" >/dev/null 2>&1 || true
    git -C "$WORK" push -q origin --delete "$BR" >/dev/null 2>&1 || true
    git -C "$WORK" checkout -qb "$BR"
    # 注错：把 gcd(48,18)=6 翻转成 7 —— JUnit failure 应精确指向 smoke_gcd
    python3 - "$WORK" <<'PY'
import sys
f = sys.argv[1] + "/tb/tb_gcd.py"
s = open(f).read()
s = s.replace("(48, 18, 6),", "(48, 18, 7),   # unit-demo: 期望值注错")
open(f, "w").write(s)
PY
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "demo: 翻转 tb 期望值（48,18 期望 7）"
    git -C "$WORK" push -q origin "$BR" >/dev/null 2>&1 || true
    local pid resp new_iid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    resp=$(curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/merge_requests" \
        -d "source_branch=$BR" -d "target_branch=main" \
        -d "title=demo: unit 仿真注错验证")
    new_iid=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('iid',''))" 2>/dev/null || true)
    [ -n "$new_iid" ] || { echo "[fail] MR 创建失败：${resp:0:200}" >&2; exit 1; }
    echo "$pid $new_iid"
}

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
    local pid="$1" pl="$2"
    for _ in $(seq 1 50); do
        local st
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) echo "$st"; return 0;; esac
        sleep 5
    done
    echo timeout
}

fetch_junit() {
    # 下载 job 归档 zip，返回 sim/results.xml 的 (tests, failures)
    local jid="$1"
    api "projects/$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")/jobs/$jid/artifacts" > /tmp/unit_art.zip
    python3 - <<'PY'
import zipfile, xml.etree.ElementTree as ET
z = zipfile.ZipFile("/tmp/unit_art.zip")
name = [n for n in z.namelist() if n.endswith("results.xml")][0]
root = ET.fromstring(z.read(name))
suite = root.find("testsuite") if root.tag == "testsuites" else root
print(suite.get("tests", "0"), suite.get("failures", "0"), suite.get("errors", "0"),
      (suite.find("testcase").get("name") if suite.find("testcase") is not None else "-"))
PY
}

do_up() {
    ensure_ci
}

do_verify() {
    local FAILED=0
    step demo "注错 → unit 必须红 + JUnit failure 指向用例"
    local raw pid mr_iid
    raw=$(open_bug_mr)
    echo "  [  =] open_bug_mr 输出：$(echo "$raw" | tail -1)"
    pid=$(echo "$raw" | tail -1 | awk '{print $1}')
    mr_iid=$(echo "$raw" | tail -1 | awk '{print $2}')
    git -C "$WORK" commit -q --allow-empty -m "demo: 触发 MR 流水线" && git -C "$WORK" push -q origin "$BR" >/dev/null 2>&1 || true
    local sha pl st
    sha=$(git -C "$WORK" rev-parse HEAD)
    read -r pl st <<<"$(wait_pipeline_for_sha "$pid" "$sha")"
    st=$(wait_pipeline_done "$pid" "$pl")
    local unit_id
    unit_id=$(api "projects/$pid/pipelines/$pl/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'unit':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
    [ -n "$unit_id" ] || { fail "找不到 unit job"; exit 1; }
    if [ "$st" = "failed" ]; then
        pass "注错 MR 的 unit job 红（pipeline #$pl failed）"
    else
        fail "注错后 pipeline=$st（期望 failed）"; FAILED=1
    fi
    local junit
    junit=$(fetch_junit "$unit_id" 2>/dev/null || true)
    local tests fails case_name
    tests=$(echo "$junit" | awk '{print $1}')
    fails=$(echo "$junit" | awk '{print $2}')
    case_name=$(echo "$junit" | awk '{print $4}')
    if [ "$tests" = "1" ] && [ "$fails" = "1" ] && [ "$case_name" = "smoke_gcd" ]; then
        pass "JUnit：tests=1 failures=1，failure 精确指向 $case_name"
    else
        fail "JUnit：tests=$tests failures=$fails case=$case_name"; FAILED=1
    fi

    step demo "修复 → unit 全绿"
    git -C "$WORK" checkout -q "$BR"
    git -C "$WORK" checkout -q main -- tb/tb_gcd.py    # 从 main 还原 tb：期望值回 6
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "fix: 还原期望值（48,18 → 6）"
    git -C "$WORK" push -q origin "$BR" >/dev/null 2>&1 || true
    sha=$(git -C "$WORK" rev-parse HEAD)
    read -r pl2 st2 <<<"$(wait_pipeline_for_sha "$pid" "$sha")"
    st2=$(wait_pipeline_done "$pid" "$pl2")
    if [ "$st2" = "success" ]; then
        pass "修复后 MR 流水线全绿（pipeline #$pl2 success）"
    else
        fail "修复后 pipeline=${st2}（期望 success）"; FAILED=1
    fi
    local unit_id2 junit2 t2 f2
    unit_id2=$(api "projects/$pid/pipelines/$pl2/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'unit' and j['status'] == 'success':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
    junit2=$(fetch_junit "$unit_id2" 2>/dev/null || true)
    t2=$(echo "$junit2" | awk '{print $1}'); f2=$(echo "$junit2" | awk '{print $2}')
    if [ "$t2" = "1" ] && [ "$f2" = "0" ]; then
        pass "JUnit：tests=1 failures=0（MR 测试 Tab 数据可拉取）"
    else
        fail "JUnit：tests=${t2} failures=${f2}（期望 1/0）"; FAILED=1
    fi
    git -C "$WORK" checkout -q main

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 9 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
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
