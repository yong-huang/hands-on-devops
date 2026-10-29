#!/usr/bin/env bash
# =============================================================================
# 02 · 节点类型与内建函数 — node_types / data_types / 约束 / get_property vs get_attribute
#
# 用法：
#   ./types_functions.sh validate        # 蓝图静态校验
#   ./types_functions.sh constraints     # 三条非法 input 必须被拒（各用全新 workdir）
#   ./types_functions.sh install         # init + install（两实例共用一个自定义 type）
#   ./types_functions.sh outputs         # 8 个输出值逐项断言（含 get_property/get_attribute 对照）
#   ./types_functions.sh evolution       # 改 node_type 默认 workers 2→5 → 两实例输出同步变化
#   ./types_functions.sh                 # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=types

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {  # must_contain <file> <pattern> <说明>
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

must_absent() {  # must_absent <file> <pattern> <说明>
    ! grep -qE "$2" "$1" || fail "$3（日志 $1 不应出现 /$2/）"
    ok "$3"
}

do_validate() {
    step validate "自定义类型蓝图通过 validate"
    cfy_run validate blueprints validate bp.yaml
    must_contain .logs/validate.log "validated successfully" "validate 通过"
}

do_constraints() {
    step constraints "非法 input 必须在解析期被拒（valid_values / pattern / in_range）"
    # 失败的 init 会留下半初始化上下文（下一次 init 报 Errno 2），每条用例先重置 workdir
    reset_workdir
    cfy_run constraint-env init -b "$DEP" bp.yaml -i env=bogus || true
    must_contain .logs/constraint-env.log \
        "Value bogus of input env violates constraint valid_values" "env=bogus 被 valid_values 拒绝"

    reset_workdir
    cfy_run constraint-team init -b "$DEP" bp.yaml -i team=Platform || true
    must_contain .logs/constraint-team.log \
        "Value Platform of input team violates constraint pattern" "team=Platform 被 pattern 拒绝"

    # 上游怪癖：-i 传参恒为字符串，整数 input 的 in_range 报的是类型比较错误（但确实拒绝）
    reset_workdir
    cfy_run constraint-port init -b "$DEP" bp.yaml -i port=70000 || true
    must_contain .logs/constraint-port.log "not comparable" "port=70000 被 in_range 拒绝（报错形态见 README）"
    reset_workdir
}

do_install() {
    step install "init + install：alpha 覆盖标量属性，beta 全部用类型默认"
    cfy_run init init -b "$DEP" bp.yaml
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    must_contain .logs/install.log \
        "static worker_name=alpha-worker, config.name=default-worker, config.workers=2" \
        "脚本经 ctx.node.properties 读到静态属性"
    [ "$(alive_count "$DEP")" = "2" ] || fail "活跃实例数应为 2，实为 $(alive_count "$DEP")"
    ok "本地存储活跃实例数 = 2"
}

do_outputs() {
    step outputs "8 个输出逐项断言（get_property vs get_attribute 同键对照）"
    cfy_run outputs deployments outputs -b "$DEP"
    local f=.logs/outputs.log
    must_contain "$f" '"alpha_static_name": "alpha-worker"' "get_property：实例覆盖值"
    must_contain "$f" '"alpha_runtime_name": "runtime-alpha_[a-z0-9]{6}"' "get_attribute：脚本覆写后的同名键"
    must_contain "$f" '"beta_static_name": "worker-default"' "get_property：类型默认值"
    must_contain "$f" '"beta_workers": 2' "嵌套 data_type 默认（演化前 2）"
    must_contain "$f" '"alpha_workers_runtime": 2' "脚本读到的 config.workers"
    must_contain "$f" '"endpoint": "http://alpha-worker/dev"' "concat 全字符串拼接"
    must_contain "$f" '"env_upper": "DEV"' "string_upper"
    must_contain "$f" '"team_tag": "Platform"' "string_replace（str.replace 语义）"
    must_absent  "$f" '"alpha_runtime_name": "alpha-worker"' "同名键未被静态值污染"
}

do_evolution() {
    step evolution "改 node_type 默认 workers 2→5：两实例输出同步变化（trap 还原源文件）"
    cp bp.yaml .bp.yaml.bak
    sed -i '' 's/^        default: 2$/        default: 5/' bp.yaml
    reset_workdir
    cfy_run init-evo init -b "$DEP" bp.yaml
    cfy_run install-evo executions start install -b "$DEP"
    cfy_run outputs-evo deployments outputs -b "$DEP"
    must_contain .logs/outputs-evo.log '"beta_workers": 5'  "beta 走新默认 = 5"
    must_contain .logs/outputs-evo.log '"alpha_workers_runtime": 5' "alpha 同步 = 5（无实例级覆盖）"
    must_contain .logs/outputs-evo.log '"alpha_static_name": "alpha-worker"' "实例级覆盖不受默认演化影响"
}

restore_bp() {
    # 备份只在 trap 里消费（mv 自删）；勿在阶段内提前 rm，否则中断后无法还原
    if [ -f .bp.yaml.bak ]; then mv .bp.yaml.bak bp.yaml; fi
    return 0
}
trap restore_bp EXIT

case "${1:-all}" in
    validate)    do_validate ;;
    constraints) do_constraints ;;
    install)     do_install ;;
    outputs)     do_outputs ;;
    evolution)   do_evolution ;;
    all)
        do_validate
        do_constraints
        do_install
        do_outputs
        do_evolution
        # 收尾：直接在 evolution 留下的 workdir 上卸载（reset 会丢蓝图上下文）
        cfy_run uninstall executions start uninstall -b "$DEP"
        [ "$(alive_count "$DEP")" = "0" ] || fail "收尾清理后仍有活跃实例"
        ok "收尾 uninstall 零活跃实例"
        echo; echo "✅ 02 全部通过"
        ;;
    *) echo "用法: $0 [validate|constraints|install|outputs|evolution|all]"; exit 1 ;;
esac
