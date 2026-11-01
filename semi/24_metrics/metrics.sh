#!/usr/bin/env bash
# semi/24_metrics · 流水线度量（DORA 四指标 + 瓶颈定位）
# 用法：./metrics.sh up | verify | status
#   up     推 dora_report.py 到 rtl-gcd（tools/）
#   verify ①真实数据集跑通：输出周报 JSON 且瓶颈 stage 与流水线聚合一致 ②3红7绿单测
#   status 周报 JSON
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }

do_up() {
    step up "推 dora_report.py 到 rtl-gcd（幂等）"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    if cmp -s tools/dora_report.py "$WORK/tools/dora_report.py"; then
        echo "[  =] 内容一致，跳过"
    else
        mkdir -p "$WORK/tools"
        cp tools/dora_report.py "$WORK/tools/"
        git -C "$WORK" add tools/dora_report.py
        git -C "$WORK" commit -qm "ci: DORA 四指标周报（瓶颈 stage 定位）"
        git -C "$WORK" push -q origin main
        pass "已推 main"
    fi
}

do_verify() {
    local FAILED=0
    step verify1 "已知数据集单测（3 红 7 绿：成功率 70%、CFR 30%、MTTR 60min）"
    if python3 -m unittest tools.test_dora -v 2>&1 | tee /tmp/dora_test.log | grep -q "^OK"; then
        pass "单测全过（计数/CFR/MTTR 数学正确）"
    else
        fail "单测失败：$(tail -3 /tmp/dora_test.log)"; FAILED=1
    fi

    step verify2 "真实数据集：周报 JSON + 瓶颈 stage"
    python3 tools/dora_report.py "$TOKEN_FILE" "semi/ip/design/rtl-gcd" "$(pwd)/dora_week.json" || FAILED=1
    local worst
    worst=$(python3 -c "import json;print(json.load(open('dora_week.json'))['worst_stage']['stage'])")
    # 交叉验证：从 API 独立聚合各 stage 总耗时，排序第一应与报告一致
    python3 - "$URL" "$(cat "$TOKEN_FILE")" "$worst" <<'PY' || FAILED=1
import sys, json, gitlab
gl = gitlab.Gitlab(sys.argv[1], private_token=sys.argv[2], retry_transient_errors=True)
p = gl.projects.get("semi/ip/design/rtl-gcd")
stage_time = {}
for pl in p.pipelines.list(get_all=True, per_page=20):   # 与报告同窗：最近 20 条全 ref
    try:
        for j in p.pipelines.get(pl.id).jobs.list(get_all=True):
            if j.duration:
                stage_time[j.stage] = stage_time.get(j.stage, 0) + j.duration
    except Exception:
        continue
top = max(stage_time.items(), key=lambda x: x[1])[0]
print(f"  [  =] API 独立聚合瓶颈: {top}")
assert top == sys.argv[3], f"瓶颈不一致：报告 {sys.argv[3]} vs 独立聚合 {top}"
print("  [ok]   瓶颈 stage 与独立聚合一致")
PY

    echo
    [ "$FAILED" = 0 ] && echo "[ok] 项目 24 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "dora_week.json"
    python3 -m json.tool dora_week.json 2>/dev/null | head -14 || echo "  (未生成)"
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
