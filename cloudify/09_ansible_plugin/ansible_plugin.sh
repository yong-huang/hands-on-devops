#!/usr/bin/env bash
# =============================================================================
# 09 · ⛓️ Ansible 插件 — docker 插件起容器、establish 钩子里跑 playbook、幂等重跑
#
# 主线：docker 插件起 python:3.12-slim 容器（自带 python3），connected_to 的
#       establish 源操作生成本地 inventory（community.docker 连接）并执行
#       ansible-playbook；execute_operation 重跑证明幂等。官方插件负向留证。
# 用法：
#   ./ansible_plugin.sh official-neg  # 官方 ansible 插件 install 快速失败（负向留证）
#   ./ansible_plugin.sh install       # 容器起 → 首次配置（changed>0）→ 行序断言
#   ./ansible_plugin.sh idempotent    # execute_operation 重跑 → changed=0
#   ./ansible_plugin.sh uninstall     # 零容器 + 零 stage 残留
#   ./ansible_plugin.sh               # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=ans
STAGE=/tmp/handson09

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

# 日志行号工具
first_line() {
    grep -nE "$2" "$1" | head -1 | cut -d: -f1
}

cleanup_all() {
    docker rm -f cfy09-app >/dev/null 2>&1 || true
    rm -rf "$STAGE"
    return 0
}

stage_files() {
    mkdir -p "$STAGE"
    cp playbooks/site.yaml "$STAGE/site.yaml"
}

do_official_neg() {
    step official-neg "官方 ansible 插件：validate 通过，install 因 Manager 路径缺失快速失败"
    cfy_run official-validate blueprints validate bp_official.yaml
    must_contain .logs/official-validate.log "validated successfully" "官方蓝图静态 validate 通过"
    reset_workdir
    cfy_run official-init init -b "${DEP}_off" bp_official.yaml
    cfy_run official-install executions start install -b "${DEP}_off" || true
    must_contain .logs/official-install.log \
        "Task failed 'cloudify_ansible.tasks.precreate'" \
        "precreate 即失败（Manager 文件系统路径不存在，负向留证）"
    reset_workdir
}

do_install() {
    step install "docker 插件起容器 → establish 钩子跑 ansible-playbook（首次 changed>0）"
    cleanup_all
    reset_workdir
    stage_files
    cfy_run init init -b "$DEP" bp.yaml
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    [ "$(alive_count "$DEP")" = "2" ] || fail "活跃实例数应为 2（app + configure），实为 $(alive_count "$DEP")"
    ok "活跃实例数 = 2"
    local app_create recap
    app_create=$(first_line .logs/install.log '\[app_[a-z0-9]+\] Node instance created')
    recap=$(first_line .logs/install.log 'ansible inventory written')
    [ -n "$app_create" ] && [ -n "$recap" ] || fail "日志缺关键行"
    [ "$app_create" -lt "$recap" ] || fail "容器 created(行 $app_create) 应早于 ansible 配置(行 $recap)"
    ok "行序：容器 created（行 ${app_create}）→ ansible 配置（行 ${recap}）"
    [ "$(inst_attr "$DEP" ansible_changed)" = "yes" ] || fail "首次配置 ansible_changed 应为 yes"
    ok "首次配置有变更（ansible_changed=yes）"
    local motd
    motd=$(docker exec cfy09-app cat /etc/motd)
    [ "$motd" = "configured by cloudify experiment 09" ] || fail "容器内 /etc/motd 内容不符：$motd"
    ok "docker exec 验证容器内文件已配置"
}

do_idempotent() {
    step idempotent "execute_operation 重跑同一配置 → changed=0"
    cfy_run reconfigure executions start execute_operation -b "$DEP" \
        -p '{"operation": "handson.interfaces.maintenance.reconfigure"}'
    must_contain .logs/reconfigure.log "'execute_operation' workflow execution succeeded" "重跑执行成功"
    [ "$(inst_attr "$DEP" ansible_changed)" = "no" ] || fail \
        "重跑应为无变更（ansible_changed=no），实为 $(inst_attr "$DEP" ansible_changed)"
    ok "重跑零变更（幂等，copy/lineinfile 内容已一致）"
    local motd
    motd=$(docker exec cfy09-app cat /etc/motd)
    [ "$motd" = "configured by cloudify experiment 09" ] || fail "重跑后容器内文件内容不符"
    ok "容器内文件保持正确"
}

do_uninstall() {
    step uninstall "零容器 + 零 stage 残留"
    cfy_run uninstall executions start uninstall -b "$DEP"
    must_contain .logs/uninstall.log "'uninstall' workflow execution succeeded" "uninstall 工作流成功"
    [ "$(docker ps -aq --filter name=cfy09- | wc -l | tr -d ' ')" = "0" ] || fail "容器残留"
    ok "零容器残留"
    cleanup_all   # stage 目录是实验装置（playbook/inventory 由主脚本 stage），归主脚本清理
    [ ! -d "$STAGE" ] || fail "stage 目录清理失败：$STAGE"
    ok "零 stage 残留"
}

case "${1:-all}" in
    official-neg) do_official_neg ;;
    install)      do_install ;;
    idempotent)   do_idempotent ;;
    uninstall)    do_uninstall ;;
    all)
        do_official_neg
        do_install
        do_idempotent
        do_uninstall
        echo; echo "✅ 09 全部通过"
        ;;
    *) echo "用法: $0 [official-neg|install|idempotent|uninstall|all]"; exit 1 ;;
esac
