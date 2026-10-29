#!/usr/bin/env bash
# =============================================================================
# 03 · 关系与生命周期 — connected_to/contained_in、source_interfaces 钩子与实例数相乘
#
# 用法：
#   ./relationships.sh validate     # 蓝图静态校验
#   ./relationships.sh install      # init + install（8 实例：db+app+3host+3worker）
#   ./relationships.sh order        # 安装顺序：db started 早于 app create；establish 跨节点传值
#   ./relationships.sh outputs      # db_endpoint 断言（多实例节点 get_attribute 会报错，证据走存储）
#   ./relationships.sh uninstall    # 卸载顺序：app 先于 db；containee 先于 container；零活跃实例
#   ./relationships.sh              # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=rel

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

# 日志行号工具：某模式的首次出现行号
first_line() {  # first_line <file> <pattern>
    grep -nE "$2" "$1" | head -1 | cut -d: -f1
}

count_alive() {  # count_alive <node-id 前缀>
    python3 "$CQ" "$CFY_WORKDIR" "$DEP" --alive | grep -c "^$1" || true
}

do_validate() {
    step validate "关系蓝图通过 validate（dsl_1_5 用 source_interfaces，不是老语法 source_operations）"
    cfy_run validate blueprints validate bp.yaml
    must_contain .logs/validate.log "validated successfully" "validate 通过"
}

do_install() {
    step install "init + install：db/app + host×3（worker contained_in）"
    cfy_run init init -b "$DEP" bp.yaml
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    [ "$(alive_count "$DEP")" = "8" ] || fail "活跃实例总数应为 8，实为 $(alive_count "$DEP")"
    ok "活跃实例总数 = 8"
    [ "$(count_alive worker_)" = "3" ] || fail "worker 实例应为 3（deploy 相乘），实为 $(count_alive worker_)"
    ok "worker 实例数 = 3（host deploy:3 相乘）"
    [ "$(count_alive host_)" = "3" ] || fail "host 实例应为 3，实为 $(count_alive host_)"
    ok "host 实例数 = 3"
}

do_order() {
    step order "安装顺序与关系钩子"
    local db_start app_create
    db_start=$(first_line .logs/install.log '\[db_[a-z0-9]+\] Node instance started')
    app_create=$(first_line .logs/install.log '\[app_[a-z0-9]+\.create\] Task started')
    [ -n "$db_start" ] && [ -n "$app_create" ] || fail "日志中找不到 db/app 关键事件行"
    [ "$db_start" -lt "$app_create" ] || fail "db started(行 $db_start) 应早于 app create(行 $app_create)"
    ok "db Node instance started（行 ${db_start}）早于 app create（行 ${app_create}）——依赖序生效"

    must_contain .logs/install.log \
        'establish: app_[a-z0-9]+ <- db_[a-z0-9]+ \(10\.200\.0\.10:5432\)' \
        "establish 源操作经 ctx.target 读 db、写回 app（跨节点数据流）"
    must_contain .logs/install.log 'relationship_lifecycle.*establish|relationship.*establish' \
        "日志含 relationship establish 生命周期事件"
}

do_outputs() {
    step outputs "单实例节点输出断言（多实例 get_attribute 本地模式报错，见 README）"
    cfy_run outputs deployments outputs -b "$DEP"
    must_contain .logs/outputs.log '"db_endpoint": "10\.200\.0\.10:5432"' "outputs.db_endpoint 来自 establish 写入"
    must_contain .logs/outputs.log 'More than one node instance found' "多实例 get_attribute 报歧义错误（负向事实留证）"
}

do_uninstall() {
    step uninstall "卸载顺序与清理"
    cfy_run uninstall executions start uninstall -b "$DEP"
    must_contain .logs/uninstall.log "'uninstall' workflow execution succeeded" "uninstall 工作流成功"
    local app_del db_del first_del
    app_del=$(first_line .logs/uninstall.log '\[app_[a-z0-9]+\] Deleted node instance')
    db_del=$(first_line .logs/uninstall.log '\[db_[a-z0-9]+\] Deleted node instance')
    [ -n "$app_del" ] && [ -n "$db_del" ] || fail "日志中找不到删除事件行"
    [ "$app_del" -lt "$db_del" ] || fail "app Deleted(行 $app_del) 应早于 db Deleted(行 $db_del)"
    ok "app 先于 db 删除（行 ${app_del} < 行 ${db_del}）——卸载严格逆序"
    first_del=$(grep -E "Deleted node instance" .logs/uninstall.log | head -1 | grep -oE '\[[a-z]+_' | cut -d_ -f1 | tr -d '[')
    case "$first_del" in
        worker|app) ok "首个删除实例是 ${first_del}（containee 先于 container，非 db/host）" ;;
        *) fail "首个删除实例是 ${first_del}，应为 worker/app" ;;
    esac
    [ "$(alive_count "$DEP")" = "0" ] || fail "收尾后仍有 $(alive_count "$DEP") 个活跃实例"
    ok "收尾零活跃实例"
}

case "${1:-all}" in
    validate)  do_validate ;;
    install)   do_install ;;
    order)     do_order ;;
    outputs)   do_outputs ;;
    uninstall) do_uninstall ;;
    all)
        do_validate
        reset_workdir
        do_install
        do_order
        do_outputs
        do_uninstall
        echo; echo "✅ 03 全部通过"
        ;;
    *) echo "用法: $0 [validate|install|order|outputs|uninstall|all]"; exit 1 ;;
esac
