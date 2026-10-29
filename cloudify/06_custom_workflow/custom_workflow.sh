#!/usr/bin/env bash
# =============================================================================
# 06 · 自定义工作流 — @workflow 任务图、批次滚动重启与执行并发度
#
# 关键实测：并发度由执行配置 --task-thread-pool-size 决定（默认 1=串行）；
# 图里无依赖的任务才并发；parameters.constraints 本地不校验（工作流内自检兜底）。
# 用法：
#   ./custom_workflow.sh install       # init + install（3 实例 Service）
#   ./custom_workflow.sh serial        # batch=1：3 批次串行，总时长 ≥2.8s
#   ./custom_workflow.sh parallel      # batch=3 + 池 3：1 批并发，总时长 <2.5s
#   ./custom_workflow.sh bad-batch     # batch=-1：工作流自检拒绝（执行失败）
#   ./custom_workflow.sh uninstall     # 清理
#   ./custom_workflow.sh               # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=flow

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

# 日志首尾时间戳差（秒）
span_seconds() {  # span_seconds <log>
    python3 - "$1" <<'PYEOF'
import re, sys
from datetime import datetime
lines = open(sys.argv[1]).read().splitlines()
stamps = [datetime.strptime(l[:23], "%Y-%m-%d %H:%M:%S.%f")
          for l in lines if re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:", l)]
print("{:.2f}".format((stamps[-1] - stamps[0]).total_seconds()) if stamps else "0.00")
PYEOF
}

do_install() {
    step install "init + install（3 实例 Service，restart 接口已就绪）"
    reset_workdir
    cfy_run init init -b "$DEP" bp.yaml
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    [ "$(alive_count "$DEP")" = "3" ] || fail "活跃实例数应为 3，实为 $(alive_count "$DEP")"
    ok "活跃实例数 = 3"
}

do_serial() {
    step serial "batch=1：3 批次链式依赖 → 严格串行（3 次 1s 重启逐个进行）"
    cfy_run serial executions start rolling_restart -b "$DEP" -p batch=1
    must_contain .logs/serial.log "'rolling_restart' workflow execution succeeded" "batch=1 执行成功"
    local batches span
    batches=$(grep -cE "Subgraph succeeded 'batch-" .logs/serial.log || true)
    [ "$batches" = "3" ] || fail "batch=1 应产生 3 个批次子图，实为 $batches"
    ok "批次子图数 = 3（链式依赖）"
    span=$(span_seconds .logs/serial.log)
    python3 -c "assert float('$span') >= 2.8, 'span=$span'" || fail "串行总时长 $span 应 ≥2.8s"
    ok "串行总时长 ${span}s（3×1s 重启逐个进行）"
}

do_parallel() {
    step parallel "batch=3 + --task-thread-pool-size 3：同批无依赖任务并发（总时长 ~1s）"
    cfy_run parallel executions start rolling_restart -b "$DEP" \
        -p batch=3 --task-thread-pool-size 3
    must_contain .logs/parallel.log "'rolling_restart' workflow execution succeeded" "batch=3 执行成功"
    local batches span
    batches=$(grep -cE "Subgraph succeeded 'batch-" .logs/parallel.log || true)
    [ "$batches" = "1" ] || fail "batch=3 应只有 1 个批次子图，实为 $batches"
    ok "批次子图数 = 1（同批无依赖）"
    span=$(span_seconds .logs/parallel.log)
    python3 -c "assert float('$span') < 2.5, 'span=$span'" || fail "并发总时长 $span 应 <2.5s（3 个 1s 任务重叠）"
    ok "并发总时长 ${span}s（3 个 1s 重启重叠执行，池=3）"
    [ "$(inst_attr "$DEP" restart_at | grep -c .)" = "3" ] || fail "restart_at 应覆盖 3 实例"
    ok "3 个实例 restart_at 全部写入（存储证据）"
}

do_bad_batch() {
    step bad-batch "batch=-1：parameters 约束本地不校验 → 工作流内自检拒绝"
    cfy_run bad-batch executions start rolling_restart -b "$DEP" -p batch=-1 || true
    must_contain .logs/bad-batch.log "'rolling_restart' workflow execution failed" "非法 batch → 执行失败"
    must_contain .logs/bad-batch.log "batch must be a positive integer" "自检消息进入执行日志"
}

case "${1:-all}" in
    install)   do_install ;;
    serial)    do_serial ;;
    parallel)  do_parallel ;;
    bad-batch) do_bad_batch ;;
    uninstall)
        cfy_run uninstall executions start uninstall -b "$DEP"
        [ "$(alive_count "$DEP")" = "0" ] || fail "仍有活跃实例"
        ok "收尾零活跃实例"
        ;;
    all)
        do_install
        do_serial
        do_parallel
        do_bad_batch
        cfy_run uninstall executions start uninstall -b "$DEP"
        [ "$(alive_count "$DEP")" = "0" ] || fail "收尾后仍有活跃实例"
        ok "收尾零活跃实例"
        echo; echo "✅ 06 全部通过"
        ;;
    *) echo "用法: $0 [install|serial|parallel|bad-batch|uninstall|all]"; exit 1 ;;
esac
