#!/usr/bin/env bash
# =============================================================================
# 04 · 工作流与容错 — execute_operation、max_retries 重试、abort 不重试、ignore_failure 清理
#
# 三份蓝图各证一件事：bp.yaml（重试后成功 + 自定义接口）、bp_exhaust.yaml（重试耗尽）、
# bp_fatal.yaml（ctx.abort_operation 立即终止）。scale/heal 是 Manager 专属（本地报
# "Implemented by subclasses"），不在此列——见清单项目 12。
# 用法：
#   ./workflows_retry.sh validate      # 三份蓝图静态校验
#   ./workflows_retry.sh retry-success # flaky 前 2 次失败第 3 次成功（max_retries: 3）
#   ./workflows_retry.sh execute-op    # execute_operation 对 data×2 各执行一次 backup
#   ./workflows_retry.sh exhaust       # max_retries: 1 耗尽 → install 失败 → ignore_failure 清理
#   ./workflows_retry.sh fatal         # ctx.abort_operation：1 次执行、不重试、执行失败
#   ./workflows_retry.sh               # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=wf
DEP_X=wfx
DEP_F=wff
COUNTER=/tmp/handson04-flaky.count
COUNTER_X=/tmp/handson04-flaky1.count

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

task_starts() {  # task_starts <log> <node-prefix>
    grep -cE "\\[$2_[a-z0-9]+\.create\] Task started" "$1" || true
}

do_validate() {
    step validate "三份蓝图全部通过 validate"
    for bp in bp.yaml bp_exhaust.yaml bp_fatal.yaml; do
        cfy_run "validate-${bp%.yaml}" blueprints validate "$bp"
        must_contain ".logs/validate-${bp%.yaml}.log" "validated successfully" "$bp validate 通过"
    done
}

do_retry_success() {
    step retry-success "max_retries: 3——前 2 次失败、第 3 次成功（计数文件制造确定性故障）"
    reset_workdir
    rm -f "$COUNTER"
    cfy_run init init -b "$DEP" bp.yaml
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    [ "$(task_starts .logs/install.log flaky)" = "3" ] || fail \
        "flaky create 应执行 3 次（2 败 1 成），实为 $(task_starts .logs/install.log flaky)"
    ok "flaky create 执行 3 次"
    must_contain .logs/install.log "Task failed 'script_runner.tasks.run'.*\[retry 1/3\]" "第 1 次失败进重试 [1/3]"
    must_contain .logs/install.log "Task succeeded 'script_runner.tasks.run'.*\[retry 2/3\]" "第 3 次执行在 [2/3] 成功"
    [ "$(inst_attr "$DEP" attempts)" = "3" ] || fail "runtime property attempts 应为 3，实为 $(inst_attr "$DEP" attempts)"
    ok "runtime property attempts = 3"
}

do_execute_op() {
    step execute-op "execute_operation 调自定义接口 handson.interfaces.maintenance.backup"
    cfy_run exec-op executions start execute_operation -b "$DEP" \
        -p operation=handson.interfaces.maintenance.backup
    must_contain .logs/exec-op.log "'execute_operation' workflow execution succeeded" "execute_operation 成功"
    local n
    n=$(python3 "$CQ" "$CFY_WORKDIR" "$DEP" --alive --attr backup_at | grep -c . || true)
    [ "$n" = "2" ] || fail "backup 应覆盖 data 的 2 个实例，实为 $n"
    ok "data×2 实例各拿到 backup_at（证据走存储）"
}

do_exhaust() {
    step exhaust "max_retries: 1——耗尽即失败，uninstall -p ignore_failure=true 兜底清理"
    reset_workdir
    rm -f "$COUNTER_X"
    cfy_run init-x init -b "$DEP_X" bp_exhaust.yaml
    cfy_run install-x executions start install -b "$DEP_X" || true
    must_contain .logs/install-x.log "'install' workflow execution failed" "重试耗尽 → install 失败"
    [ "$(task_starts .logs/install-x.log flaky)" = "2" ] || fail \
        "max_retries:1 应执行 2 次（初始 + 1 重试），实为 $(task_starts .logs/install-x.log flaky)"
    ok "flaky create 恰好执行 2 次"
    cfy_run uninstall-x executions start uninstall -b "$DEP_X" -p ignore_failure=true
    must_contain .logs/uninstall-x.log "'uninstall' workflow execution succeeded" "ignore_failure 卸载成功"
    [ "$(alive_count "$DEP_X")" = "0" ] || fail "清理后仍有 $(alive_count "$DEP_X") 个活跃实例"
    ok "失败安装后清理干净（零活跃实例）"
}

do_fatal() {
    step fatal "ctx.abort_operation——立即失败，绝不重试"
    reset_workdir
    cfy_run init-f init -b "$DEP_F" bp_fatal.yaml
    cfy_run install-f executions start install -b "$DEP_F" || true
    must_contain .logs/install-f.log "'install' workflow execution failed" "abort → install 失败"
    [ "$(task_starts .logs/install-f.log fatal)" = "1" ] || fail \
        "abort 后不应重试，应仅执行 1 次，实为 $(task_starts .logs/install-f.log fatal)"
    ok "fatal create 仅执行 1 次（零重试）"
    must_contain .logs/install-f.log "fatal: unrecoverable condition detected" "abort 消息进入执行日志"
    reset_workdir
}

case "${1:-all}" in
    validate)     do_validate ;;
    retry-success) do_retry_success ;;
    execute-op)   do_execute_op ;;
    exhaust)      do_exhaust ;;
    fatal)        do_fatal ;;
    all)
        do_validate
        do_retry_success
        do_execute_op
        do_exhaust
        do_fatal
        echo; echo "✅ 04 全部通过"
        ;;
    *) echo "用法: $0 [validate|retry-success|execute-op|exhaust|fatal|all]"; exit 1 ;;
esac
