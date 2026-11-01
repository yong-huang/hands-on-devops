#!/usr/bin/env bash
# semi/08_lint_gate · Lint 门禁（verilator 把住 MR 第一道关）
# 用法：./lint_gate.sh up | verify | status | clean
#   up     克隆 rtl-gcd 规范克隆 → 装 .gitlab-ci.yml（lint job + codequality 上报）→ 推 main
#   verify 注错→MR→lint 红+codequality≥1 → 修复→绿（清单验收全流程）
#   status rtl-gcd 最近流水线与 lint job
#   clean  删演示分支与 MR（lint 门禁本身保留——平台资产）
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK=".work/rtl-gcd"
FULL="semi/ip/design/rtl-gcd"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

fresh_clone() {
    rm -rf "$WORK"
    mkdir -p .work
    git clone -q "http://root:$(cat "$TOKEN_FILE")@localhost:28200/$FULL.git" "$WORK"
    git -C "$WORK" config user.name root
    git -C "$WORK" config user.email admin@example.com
}

CI_YML='.gitlab-ci.yml'

install_lint() {
    step install "rtl-gcd 装 lint 门禁（幂等）"
    [ -d "$WORK/.git" ] || fresh_clone
    local want
    want=$(cat configs/gitlab-ci.yml)
    local cur=""
    if [ -f "$WORK/$CI_YML" ]; then cur=$(cat "$WORK/$CI_YML"); fi
    if [ "$cur" = "$want" ]; then
        echo "[  =] .gitlab-ci.yml 内容一致，跳过"
        return 0
    fi
    cp configs/gitlab-ci.yml "$WORK/$CI_YML"
    mkdir -p "$WORK/tools"
    cp tools/verilator2codequality.py "$WORK/tools/"
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "ci: lint 门禁（verilator -Wall → codequality，告警即红）"
    git -C "$WORK" push -q origin main
    pass ".gitlab-ci.yml 已推送（含 GIT_LFS_SKIP_SMUDGE）"
}

open_bug_mr() {
    # 开演示分支：注入未驱动信号 → push → 开 MR
    local br="lint-demo-bug"
    git -C "$WORK" checkout -q main
    git -C "$WORK" branch -D "$br" 2>/dev/null || true
    git -C "$WORK" push -q origin --delete "$br" >/dev/null 2>&1 || true   # git-lfs 会往 stdout 喷 Deleted
    git -C "$WORK" checkout -qb "$br"
    cat >> "$WORK/rtl/gcd.v" <<'V'

// lint-demo：注入未驱动信号（%Warning-UNDRIVEN）
module lint_demo_bad;
    logic [7:0] undriven_wire;   // 声明后从未赋值
endmodule
V
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "demo: 注入 lint 告警（未驱动信号）"
    git -C "$WORK" push -q origin "$br"
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    local old_iid
    old_iid=$(api "projects/$pid/merge_requests?state=opened" | python3 -c "
import sys, json
for m in json.load(sys.stdin):
    if m['source_branch'] == 'lint-demo-bug':
        print(m['iid'])
        break" 2>/dev/null || true)
    if [ -n "$old_iid" ]; then
        echo "$pid $old_iid"
        return 0
    fi
    local resp new_iid
    resp=$(curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/merge_requests" \
        -d "source_branch=$br" -d "target_branch=main" \
        -d "title=demo: lint 门禁注错验证")
    new_iid=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('iid',''))" 2>/dev/null || true)
    [ -n "$new_iid" ] || { echo "[fail] MR 创建失败，响应：${resp:0:200}" >&2; exit 1; }
    echo "$pid $new_iid"
}

wait_pipeline_for_sha() {
    # 按 commit SHA 精确等待（"最新流水线"会被 auto-cancel 竞态坑：A 被 B 取消时按 ref 查到的是 A）
    local pid="$1"
    local sha="$2"
    local out=""
    for _ in $(seq 1 30); do
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
    for _ in $(seq 1 40); do
        local st
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) echo "$st"; return 0;; esac
        sleep 5
    done
    echo timeout
}

do_up() {
    fresh_clone
    install_lint
}

do_verify() {
    local FAILED=0
    [ -d "$WORK/.git" ] || { fresh_clone; install_lint; }
    step demo "注错 → MR → lint 必须红 + codequality 上报"
    local raw
    raw=$(open_bug_mr)          # git-lfs 可能往 stdout 喷杂音，ids 永远取最后一行
    echo "  [  =] open_bug_mr 输出：$(echo "$raw" | tail -1)"
    local pid mr_iid
    pid=$(echo "$raw" | tail -1 | awk '{print $1}')
    mr_iid=$(echo "$raw" | tail -1 | awk '{print $2}')
    # MR 已存在（上次验证残留）也要触发 head pipeline：推一个空提交
    git -C "$WORK" commit -q --allow-empty -m "demo: 触发 MR 流水线" && git -C "$WORK" push -q origin lint-demo-bug
    local sha_bug
    sha_bug=$(git -C "$WORK" rev-parse HEAD)
    read -r pl st <<<"$(wait_pipeline_for_sha "$pid" "$sha_bug")"
    [ "$pl" != "0" ] || { fail "MR 头部流水线未创建"; exit 1; }
    st=$(wait_pipeline_done "$pid" "$pl")
    local lint_st
    lint_st=$(api "projects/$pid/pipelines/$pl/jobs" | python3 -c "
import sys, json
for j in json.load(sys.stdin):
    if j['name'] == 'lint':
        print(j['status'])")
    if [ "$st" = "failed" ] && [ "$lint_st" = "failed" ]; then
        pass "注错 MR 的 lint job 红了（pipeline #$pl failed）"
    else
        fail "注错后 pipeline=${st} lint=${lint_st}（期望 failed）"; FAILED=1
    fi
    # codequality 报告解析：lint job 的 codequality artifact 可从 API 拉
    local lint_id=""
    for _ in 1 2 3; do
        lint_id=$(api "projects/$pid/pipelines/$pl/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'lint':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
        [ -n "$lint_id" ] && break
        sleep 3
    done
    [ -n "$lint_id" ] || { fail "找不到 lint job id（流水线 #${pl}）"; exit 1; }
    # 单文件 artifact 端点偶发 404（实测），zip 端点稳——下载 zip 后内存解析
    local n=""
    for _ in 1 2 3; do
        n=$(api "projects/$pid/jobs/$lint_id/artifacts" > /tmp/cq.zip && python3 -c "
import json, zipfile, sys
z = zipfile.ZipFile('/tmp/cq.zip')
print(len(json.loads(z.read('codequality.json'))))" 2>/dev/null || true)
        [ -n "$n" ] && break
        sleep 3
    done
    n=${n:--1}
    if [ "$n" -ge 1 ]; then
        pass "codequality.json 可从 API 拉取且含 $n 条告警"
    else
        fail "codequality 条数=${n}（期望 ≥1）"; FAILED=1
    fi

    step demo "修复 → lint 必须绿"
    git -C "$WORK" checkout -q lint-demo-bug
    python3 - "$WORK" <<'PY'
import sys
f = sys.argv[1] + "/rtl/gcd.v"
s = open(f).read()
# -Wall 下 UNUSED/DECLFILENAME 都算告警：修复 = 整块删除演示模块
s = s.split("// lint-demo: inject undriven")[0]
s = s.split("// lint-demo：注入未驱动信号")[0].rstrip() + "\n"
open(f, "w").write(s)
PY
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "fix: 删除演示模块，清 lint 告警"
    git -C "$WORK" push -q origin lint-demo-bug
    local sha_fix
    sha_fix=$(git -C "$WORK" rev-parse HEAD)
    read -r pl2 st2 <<<"$(wait_pipeline_for_sha "$pid" "$sha_fix")"
    st2=$(wait_pipeline_done "$pid" "$pl2")
    if [ "$st2" = "success" ]; then
        pass "修复后 MR 流水线全绿（pipeline #$pl2 success）"
    else
        fail "修复后 pipeline=${st2}（期望 success）"; FAILED=1
    fi
    git -C "$WORK" checkout -q main

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 8 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "rtl-gcd 最近流水线"
    api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/pipelines?per_page=3" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(f\"  #{p['iid']} {p['status']} {p['ref']}\")"
}

do_clean() {
    step clean "删演示分支与 MR"
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    for m in $(api "projects/$pid/merge_requests?state=opened" | python3 -c "
import sys, json
for m in json.load(sys.stdin):
    if m['source_branch'] == 'lint-demo-bug':
        print(m['iid'])"); do
        curl -s -X PUT -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
            "$URL/api/v4/projects/$pid/merge_requests/$m" -d "state_event=close" >/dev/null
    done
    git -C "$WORK" push -q origin --delete lint-demo-bug 2>/dev/null || true
    echo "[ok] 完成（lint 门禁保留）"
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
