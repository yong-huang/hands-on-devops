#!/usr/bin/env bash
# semi/17_fpga · FPGA 综合流水线（yosys + nextpnr-ice40 → bitstream + fmax 门禁）
# 用法：./fpga.sh up | verify | status
#   up     推 fpga stage（syn+pack+报告 fmax 门禁）+ Makefile + PCF 到 rtl-gcd
#   verify ①50MHz 约束下 fmax≥50 绿 + bitstream 产出 ②120MHz 注错 → 时序失败红
#   status 最近流水线
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
BR="fpga-demo"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() {
    # 空响应与 workhorse 纯文本 404 都当瞬时故障重试（OrbStack 抖动实测）
    local attempt out
    for attempt in 1 2 3 4 5; do
        out=$(curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1")
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
    for _ in $(seq 1 120); do
        local st
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) echo "$st"; return 0;; esac
        sleep 5
    done
    echo timeout
}

do_up() {
    step up "推 fpga stage + syn/（Makefile + PCF）到 rtl-gcd"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    local changed=0
    if ! cmp -s configs/gitlab-ci.yml "$WORK/.gitlab-ci.yml"; then
        cp configs/gitlab-ci.yml "$WORK/.gitlab-ci.yml"
        git -C "$WORK" add .gitlab-ci.yml
        changed=1
    fi
    for f in Makefile gcd.pcf; do
        if [ ! -f "$WORK/syn/$f" ] || ! cmp -s "configs/$f" "$WORK/syn/$f"; then
            mkdir -p "$WORK/syn"
            cp "configs/$f" "$WORK/syn/$f"
            git -C "$WORK" add "syn/$f"
            changed=1
        fi
    done
    if [ "$changed" = 1 ]; then
        git -C "$WORK" commit -qm "ci: FPGA 综合流水线（yosys+nextpnr-ice40，fmax 门禁）"
        git -C "$WORK" push -q origin main
        pass "fpga stage 已推 main"
    else
        echo "[  =] 内容一致，跳过"
    fi
}

run_fpga_pipeline() {
    # 参数：约束频率 → 在 fpga-demo 分支提交并触发，返回 (pl, st)
    local freq="$1"
    git -C "$WORK" checkout -q main || { echo "__PL_ST__ 0 checkout-failed"; return 1; }
    git -C "$WORK" pull -q origin main || { echo "__PL_ST__ 0 pull-failed"; return 1; }
    git -C "$WORK" branch -D "$BR" >/dev/null 2>&1 || true
    git -C "$WORK" push -q origin --delete "$BR" >/dev/null 2>&1 || true
    git -C "$WORK" checkout -qb "$BR" || { echo "__PL_ST__ 0 checkout-branch-failed"; return 1; }
    # 匹配参数化后的 "FREQ_MHZ ?= 50"（?=/= 两种赋值都覆盖），改成直接赋值以覆盖默认
    sed -i '' "s/^FREQ_MHZ .*/FREQ_MHZ = $freq/" "$WORK/syn/Makefile" 2>/dev/null ||
        sed -i "s/^FREQ_MHZ .*/FREQ_MHZ = $freq/" "$WORK/syn/Makefile"
    git -C "$WORK" add syn/Makefile
    git -C "$WORK" commit -qm "fpga: 约束 $freq MHz"
    # push 失败要可见；pipefail 下 grep 全过滤也会 exit 1，所以先存输出按 git 退出码判
    local push_log push_rc
    push_log=$(git -C "$WORK" push origin "$BR" 2>&1) && push_rc=0 || push_rc=$?
    echo "$push_log" | grep -vE "remote:|Locking|^To |new branch|git config lfs|^ \*" || true
    if [ "$push_rc" != "0" ]; then
        echo "__PL_ST__ 0 push-failed"; return 1
    fi
    # rules 只放行 MR 事件与 main：branch push 必须配 MR 才有流水线（幂等：已有则复用）
    local mr_resp mr_iid
    mr_resp=$(curl -s --max-time 20 -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/semi%2Fip%2Fdesign%2Frtl-gcd/merge_requests" \
        -d "source_branch=$BR" -d "target_branch=main" \
        -d "title=demo: FPGA 约束 $freq MHz")
    mr_iid=$(echo "$mr_resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('iid',''))" 2>/dev/null || true)
    [ -n "$mr_iid" ] || echo "[warn] MR 创建失败（可能已存在，流水线仍会触发）"
    local pid sha out pl="" st=""
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    sha=$(git -C "$WORK" rev-parse HEAD)
    out=$(wait_pipeline_for_sha "$pid" "$sha")
    read -r pl st <<<"$(echo "$out" | tail -1)"
    [ "$pl" != "0" ] && st=$(wait_pipeline_done "$pid" "$pl")
    echo "__PL_ST__ $pl $st"   # 哨兵行：调用方取最后一行解析
}

fetch_fmax() {
    # 从 fpga job 的归档取 fmax 报告
    # bash 3.2：local 同行多赋值不保证从左到右，拆行
    local pid="$1"
    local pl="$2"
    local jid
    jid=$(api "projects/$pid/pipelines/$pl/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'fpga':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
    [ -n "$jid" ] || { echo ""; return; }
    api "projects/$pid/jobs/$jid/artifacts/syn/fmax.json" | tail -1
}

do_verify() {
    local FAILED=0
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    step verify1 "50MHz 约束 → fmax ≥ 50 绿 + bitstream 产出"
    read -r pl1 st1 <<<"$(run_fpga_pipeline 50 | tail -1 | sed 's/__PL_ST__ //')"
    if [ "$st1" != "success" ]; then
        fail "50MHz 流水线 ${st1}（期望 success）"; exit 1
    fi
    pass "50MHz 流水线 success（#${pl1}）"
    local fmax jid1
    fmax=$(fetch_fmax "$pid" "$pl1")
    echo "  [  =] fmax 报告：$fmax"
    if echo "$fmax" | grep -q '"fmax_mhz"' &&
       python3 -c "import json,sys;d=json.loads(sys.argv[1]);assert d['fmax_mhz']>=50" "$fmax"; then
        pass "fmax.json 有效且 ≥ 50MHz"
    else
        fail "fmax 报告缺失或 <50：$fmax"; FAILED=1
    fi
    # bitstream 在归档 zip 里验证
    jid1=$(api "projects/$pid/pipelines/$pl1/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'fpga':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
    # 归档边生成边流：刚完成时下载会拿到截断 zip —— testzip 校验完整性，重试窗口 3 分钟
    local has_bin=""
    for _ in $(seq 1 12); do
        # 归档较大且 workhorse 流式生成慢：--max-time 20 会截断（实测固定 ~6.9KB 处断流）
        curl -s --max-time 180 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
            "$URL/api/v4/projects/$pid/jobs/$jid1/artifacts" > /tmp/fpga_art.zip
        has_bin=$(python3 -c "
import zipfile
try:
    z = zipfile.ZipFile('/tmp/fpga_art.zip')
    if z.testzip() is not None:
        print('truncated')
    else:
        print(any(n.endswith('.bin') for n in z.namelist()))
except Exception:
    print('badzip')" 2>/dev/null || echo badzip)
        if [ "$has_bin" = "True" ] || [ "$has_bin" = "False" ]; then
            break
        fi
        sleep 15
    done
    if [ "$has_bin" = "True" ]; then
        pass "bitstream（.bin）在归档中"
    else
        fail "归档中无 .bin"; FAILED=1
    fi

    step verify2 "200MHz 约束 → 时序失败红（实测 fmax≈120.8MHz，120 仍在裕量内）"
    read -r pl2 st2 <<<"$(run_fpga_pipeline 200 | tail -1 | sed 's/__PL_ST__ //')"
    if [ "$st2" = "failed" ]; then
        pass "200MHz 流水线 failed（时序不达标被门禁拦截）"
    else
        fail "200MHz 流水线 ${st2}（期望 failed）"; FAILED=1
    fi
    git -C "$WORK" checkout -q main

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 17 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
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
