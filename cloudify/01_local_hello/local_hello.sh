#!/usr/bin/env bash
# =============================================================================
# 01 · 第一个蓝图 — cfy 本地模式（零 Manager）、script 插件与 ctx
#
# 完整生命周期：validate(好/坏) → install → outputs → uninstall → idempotence
# 用法：
#   ./local_hello.sh validate     # 蓝图静态校验：好蓝图通过、坏 node type 被拒
#   ./local_hello.sh install      # cfy init + executions start install
#   ./local_hello.sh outputs      # deployments outputs 断言 runtime property
#   ./local_hello.sh uninstall    # uninstall + 存储层零活跃实例
#   ./local_hello.sh idempotence  # 全新 workdir 连装两遍，outputs 逐字节一致
#   ./local_hello.sh              # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=app

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {  # must_contain <file> <pattern> <说明>
    grep -q "$2" "$1" || fail "$3（日志 $1 缺少 '$2'）"
    ok "$3"
}

do_validate() {
    step validate "好蓝图通过 cfy blueprints validate"
    cfy_run validate blueprints validate bp.yaml
    must_contain .logs/validate.log "validated successfully" "好蓝图 validate 通过"

    step validate-bad "坏 node type 必须被拒，且报出 path"
    cfy_run validate-bad blueprints validate bad.yaml || true
    must_contain .logs/validate-bad.log "node_templates.hello.type" "validate 报出 path: node_templates.hello.type"
}

do_install() {
    step install "init + install（本地模式，零 Manager）"
    cfy_run init init -b "$DEP" bp.yaml
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    must_contain .logs/install.log "create.sh running for node=hello, who=hello" "ctx logger 进日志（input 注入生效）"
    must_contain .logs/install.log "script_runner.tasks.run" "script 插件任务执行"
    [ "$(alive_count "$DEP")" = "1" ] || fail "活跃实例数应为 1，实为 $(alive_count "$DEP")"
    ok "本地存储活跃实例数 = 1"
}

do_outputs() {
    step outputs "deployments outputs 读回 runtime property"
    cfy_run outputs deployments outputs -b "$DEP"
    must_contain .logs/outputs.log "hello-from-cloudify-local" "outputs 含脚本写入值"
}

do_uninstall() {
    step uninstall "uninstall 后存储层零活跃实例"
    cfy_run uninstall executions start uninstall -b "$DEP"
    must_contain .logs/uninstall.log "'uninstall' workflow execution succeeded" "uninstall 工作流成功"
    [ "$(alive_count "$DEP")" = "0" ] || fail "活跃实例数应为 0，实为 $(alive_count "$DEP")"
    ok "活跃实例数 = 0（实例记录 state=deleted）"
}

do_idempotence() {
    step idempotence "全新 workdir 连装两遍，outputs 逐字节一致"
    reset_workdir
    cfy_run init-r1 init -b "$DEP" bp.yaml
    cfy_run install-r1 executions start install -b "$DEP"
    cfy_run outputs-r1 deployments outputs -b "$DEP"
    reset_workdir
    cfy_run init-r2 init -b "$DEP" bp.yaml
    cfy_run install-r2 executions start install -b "$DEP"
    cfy_run outputs-r2 deployments outputs -b "$DEP"
    diff -q .logs/outputs-r1.log .logs/outputs-r2.log >/dev/null \
        || fail "两遍 outputs 不一致（幂等破坏）"
    ok "两遍 outputs 一致"
    cfy_run uninstall-r2 executions start uninstall -b "$DEP"
    [ "$(alive_count "$DEP")" = "0" ] || fail "收尾清理后仍有活跃实例"
}

case "${1:-all}" in
    validate)    do_validate ;;
    install)     do_install ;;
    outputs)     do_outputs ;;
    uninstall)   do_uninstall ;;
    idempotence) do_idempotence ;;
    all)
        do_validate
        reset_workdir
        do_install
        do_outputs
        do_uninstall
        do_idempotence
        echo; echo "✅ 01 全部通过"
        ;;
    *) echo "用法: $0 [validate|install|outputs|uninstall|idempotence|all]"; exit 1 ;;
esac
