#!/usr/bin/env bash
# semi/11_dag_gate · ⛓️ 集成点②：MR 全流水线（needs DAG）与注错验证
# 用法：./dag_gate.sh up | verify | status | clean
#   up     推终装 .gitlab-ci.yml（needs DAG）+ README（badge）到 rtl-gcd
#   verify ①注 lint 级错 → lint 红且 unit/sim 因 needs 未执行 ②注仿真级错 → lint 绿 unit 红 sim 未执行
#          ③修复 → 全绿 + badge 可访问
#   status 最近流水线与 rtl-gcd badge
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
FULL="semi/ip/design/rtl-gcd"
BR="dag-demo"
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
    for _ in $(seq 1 180); do
        local st
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) echo "$st"; return 0;; esac
        sleep 5
    done
    echo timeout
}

job_states() {
    # 输出 pipeline 各 job 的 name:status（去重取最新）
    api "projects/$pid/pipelines/$1/jobs" | python3 -c "
import sys, json
try:
    d = {}
    for j in sorted(json.load(sys.stdin), key=lambda x: x['id']):
        d[j['name']] = j['status']
    print(' '.join(f'{k}={v}' for k, v in d.items()))
except Exception:
    print('none')"
}

do_up() {
    step up "推终装 yml（needs DAG）+ README badge 到 rtl-gcd"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08 的 ./lint_gate.sh up"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    local changed=0
    if ! cmp -s configs/gitlab-ci.yml "$WORK/.gitlab-ci.yml"; then
        cp configs/gitlab-ci.yml "$WORK/.gitlab-ci.yml"
        git -C "$WORK" add .gitlab-ci.yml
        changed=1
    fi
    local badge
    badge="[![pipeline](http://localhost:28200/$FULL/badges/main/pipeline.svg)](http://localhost:28200/$FULL/-/commits/main)"
    if [ ! -f "$WORK/README.md" ]; then
        printf '# rtl-gcd\n\n%s\n\n半导体 CI/CD 清单的 SUT：GCD IP（RTL/TB/sim/docs + PDK/GDS/波形走 LFS）。\n' "$badge" > "$WORK/README.md"
        git -C "$WORK" add README.md
        changed=1
    fi
    if [ "$changed" = 1 ]; then
        git -C "$WORK" commit -qm "ci: needs DAG 全流水线终装 + pipeline badge"
        git -C "$WORK" push -q origin main
        pass "终装 yml + README badge 已推 main"
    else
        echo "[  =] 内容一致，跳过"
    fi
}

# 注错类型：lint（未驱动信号模块）/ sim（tb_main.cpp 期望翻转）
inject() {
    local kind="$1"
    if [ "$kind" = "lint" ]; then
        cat >> "$WORK/rtl/gcd.v" <<'V'

// dag-demo: lint 级注错（UNDRIVEN）
module dag_demo_bad;
    logic [7:0] undriven_wire;
endmodule
V
    elif [ "$kind" = "sim" ]; then
        python3 - "$WORK" <<'PY'
import sys
f = sys.argv[1] + "/sim/tb_main.cpp"
s = open(f).read()
s = s.replace("{48, 18, 6},", "{48, 18, 7},   // dag-demo: sim 级注错")
open(f, "w").write(s)
PY
    fi
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "demo: 注入 $kind 级错误"
}

revert() {
    # 从 main 还原两处注错文件
    git -C "$WORK" checkout -q main -- rtl/gcd.v sim/tb_main.cpp
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "fix: 还原全部注错"
}

do_verify() {
    local FAILED=0
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

    step demo1 "注入 lint 级错误 → lint 红，unit/sim 因 needs 未执行"
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    git -C "$WORK" branch -D "$BR" >/dev/null 2>&1 || true
    git -C "$WORK" push -q origin --delete "$BR" >/dev/null 2>&1 || true
    git -C "$WORK" checkout -qb "$BR"
    inject lint
    git -C "$WORK" push -q origin "$BR" >/dev/null 2>&1 || true
    local resp new_iid
    resp=$(curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/merge_requests" \
        -d "source_branch=$BR" -d "target_branch=main" -d "title=demo: DAG 注错（lint 级）")
    local mr1
    mr1=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('iid',''))")
    [ -n "$mr1" ] || { echo "[fail] MR 创建失败：${resp:0:150}"; exit 1; }
    local sha pl st
    sha=$(git -C "$WORK" rev-parse HEAD)
    read -r pl st <<<"$(wait_pipeline_for_sha "$pid" "$sha")"
    st=$(wait_pipeline_done "$pid" "$pl")
    local states
    states=$(job_states "$pl")
    echo "  [  =] pipeline #$pl ${st}：$states"
    if [ "$st" = "failed" ] &&
       echo "$states" | grep -q "lint=failed" &&
       echo "$states" | grep -qE "unit=(canceled|skipped)" &&
       echo "$states" | grep -qE "sim=(canceled|skipped)"; then
        pass "lint 红、unit/sim 因 needs 被跳过（DAG 生效）"
    else
        fail "期望 failed + lint=failed unit/sim 未执行，实际：$st $states"; FAILED=1
    fi
    curl -s -X PUT -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/merge_requests/$mr1" -d "state_event=close" >/dev/null

    step demo2 "注入仿真级错误 → lint 绿 unit 红 sim 不执行"
    git -C "$WORK" checkout -q "$BR"
    revert
    inject sim
    git -C "$WORK" push -q origin "$BR" >/dev/null 2>&1 || true
    resp=$(curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/merge_requests" \
        -d "source_branch=$BR" -d "target_branch=main" -d "title=demo: DAG 注错（仿真级）")
    local mr2
    mr2=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('iid',''))")
    [ -n "$mr2" ] || { echo "[fail] MR 创建失败：${resp:0:150}"; exit 1; }
    sha=$(git -C "$WORK" rev-parse HEAD)
    read -r pl st <<<"$(wait_pipeline_for_sha "$pid" "$sha")"
    st=$(wait_pipeline_done "$pid" "$pl")
    states=$(job_states "$pl")
    echo "  [  =] pipeline #$pl ${st}：$states"
    if [ "$st" = "failed" ] &&
       echo "$states" | grep -q "lint=success" &&
       echo "$states" | grep -q "unit=success" &&
       echo "$states" | grep -q "sim=failed"; then
        pass "lint 绿、unit 绿（cocotb 不受影响）、sim 红且下游无（DAG 分层正确）"
    else
        fail "期望 failed + lint/unit=success sim=failed，实际：$st $states"; FAILED=1
    fi
    curl -s -X PUT -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/merge_requests/$mr2" -d "state_event=close" >/dev/null

    step demo3 "修复 → 全绿 + badge 可访问"
    git -C "$WORK" checkout -q "$BR"
    revert
    git -C "$WORK" push -q origin "$BR" >/dev/null 2>&1 || true
    resp=$(curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/merge_requests" \
        -d "source_branch=$BR" -d "target_branch=main" -d "title=demo: DAG 修复验证")
    local mr3
    mr3=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('iid',''))")
    sha=$(git -C "$WORK" rev-parse HEAD)
    read -r pl st <<<"$(wait_pipeline_for_sha "$pid" "$sha")"
    st=$(wait_pipeline_done "$pid" "$pl")
    if [ "$st" = "success" ]; then
        pass "修复后全绿（pipeline #$pl success）"
    else
        fail "修复后 pipeline=${st}（期望 success）"; FAILED=1
    fi
    local badge_code
    badge_code=$(curl -sL -o /dev/null -w '%{http_code}' "http://localhost:28200/$FULL/badges/main/pipeline.svg")
    if [ "$badge_code" = "200" ]; then
        pass "pipeline badge 可访问（HTTP 200）"
    else
        fail "badge HTTP $badge_code"; FAILED=1
    fi
    git -C "$WORK" checkout -q main

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 11 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "rtl-gcd 最近流水线"
    api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/pipelines?per_page=3" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(f\"  #{p['iid']} {p['status']} {p['ref']}\")"
}

do_clean() {
    step clean "删演示分支（已关闭的 MR 保留为审计记录）"
    git -C "$WORK" push -q origin --delete "$BR" >/dev/null 2>&1 || true
    echo "[ok] 完成"
}

main() {
    local target="${1:-up}"
    case "${target}" in
        up)     do_up ;;
        verify) do_verify ;;
        status) do_status ;;
        clean)  do_clean ;;
        *) echo "用法: $0 up | verify | status | clean" >&2; exit 1 ;;
    esac
}
main "$@"
