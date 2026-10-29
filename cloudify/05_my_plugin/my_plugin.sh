#!/usr/bin/env bash
# =============================================================================
# 05 · 自写 Python 插件 — plugin.yaml + @operation + ctx API + MockCloudifyContext 单测
#
# 用法：
#   ./my_plugin.sh test        # pytest：MockCloudifyContext 断言 runtime property 与重试路径
#   ./my_plugin.sh validate    # 好蓝图通过；缺 required 属性被拒（附类型不校验事实）
#   ./my_plugin.sh install     # 起本地 http.server → install（HttpCheck 轮询到 200 + 渲染文件）
#   ./my_plugin.sh outputs     # status_code=200 / rendered_path 断言
#   ./my_plugin.sh uninstall   # 清理渲染文件、零活跃实例
#   ./my_plugin.sh             # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=myplug
PORT=28185
RENDER=/tmp/handson05-rendered.txt
HTTP_PID=""

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

stop_http() {
    if [ -n "$HTTP_PID" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
        kill "$HTTP_PID" 2>/dev/null || true
    fi
    return 0
}
trap stop_http EXIT

do_test() {
    step test "pytest：MockCloudifyContext 四条路径（成功/重试/渲染/缺属性）"
    ../.venv/bin/python -m pytest plugin/tests -q | tee .logs-test.txt
    grep -q "4 passed" .logs-test.txt || fail "pytest 应 4 passed"
    rm -f .logs-test.txt
    ok "pytest 4 passed（非空跑：断言了 runtime property 与 OperationRetry）"
}

do_validate() {
    step validate "好蓝图 validate 通过；缺 required 属性被拒"
    cfy_run validate blueprints validate bp.yaml
    must_contain .logs/validate.log "validated successfully" "好蓝图 validate 通过"
    cfy_run validate-bad blueprints validate bad.yaml || true
    must_contain .logs/validate-bad.log \
        "does not provide a value for mandatory 'url' property" \
        "缺 required 属性在解析期被拒"
    # 事实留证：dsl_1_5 不校验属性值类型（integer 填 string 属性照样通过）
    printf 'tosca_definitions_version: cloudify_dsl_1_5\nimports:\n  - vendor/types.yaml\n  - vendor/plugin.yaml\nnode_templates:\n  check:\n    type: handson.nodes.HttpCheck\n    properties:\n      url: 28185\n' > .logs-badtype.yaml
    cfy_run validate-badtype blueprints validate .logs-badtype.yaml || true
    must_contain .logs/validate-badtype.log "validated successfully" "类型错（url: int）实测不被拒（负向事实，见 README）"
    rm -f .logs-badtype.yaml
}

do_install() {
    step install "起本地 http.server（:${PORT}）→ init + install"
    stop_http
    (cd /tmp && python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 & echo $! > /tmp/handson05-http.pid)
    HTTP_PID=$(cat /tmp/handson05-http.pid)
    for i in 1 2 3 4 5; do
        curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
        sleep 1
    done
    reset_workdir
    rm -f "$RENDER"
    cfy_run init init -b "$DEP" bp.yaml
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    must_contain .logs/install.log "handson_plugin.tasks.check_http|handson.handson_plugin.tasks" "自写插件任务被执行"
    [ "$(alive_count "$DEP")" = "2" ] || fail "活跃实例数应为 2，实为 $(alive_count "$DEP")"
    ok "活跃实例数 = 2（check + rendered）"
}

do_outputs() {
    step outputs "插件写入的 runtime properties 经 outputs 读回"
    cfy_run outputs deployments outputs -b "$DEP"
    must_contain .logs/outputs.log '"status_code": 200' "HttpCheck runtime property status_code = 200"
    must_contain .logs/outputs.log '"rendered_path": "/tmp/handson05-rendered.txt"' "RenderedFile 记录渲染路径"
    [ "$(cat "$RENDER")" = "rendered by handson-plugin 0.1.0" ] || fail "渲染文件内容不符"
    ok "渲染文件落盘且内容正确"
}

do_uninstall() {
    step uninstall "uninstall 清理渲染文件与实例"
    cfy_run uninstall executions start uninstall -b "$DEP"
    must_contain .logs/uninstall.log "'uninstall' workflow execution succeeded" "uninstall 工作流成功"
    [ ! -f "$RENDER" ] || fail "渲染文件 $RENDER 未被 delete 操作删除"
    ok "渲染文件已由 remove_file 删除"
    [ "$(alive_count "$DEP")" = "0" ] || fail "仍有 $(alive_count "$DEP") 个活跃实例"
    ok "零活跃实例"
    stop_http
}

case "${1:-all}" in
    test)      do_test ;;
    validate)  do_validate ;;
    install)   do_install ;;
    outputs)   do_outputs ;;
    uninstall) do_uninstall ;;
    all)
        do_test
        do_validate
        do_install
        do_outputs
        do_uninstall
        echo; echo "✅ 05 全部通过"
        ;;
    *) echo "用法: $0 [test|validate|install|outputs|uninstall|all]"; exit 1 ;;
esac
