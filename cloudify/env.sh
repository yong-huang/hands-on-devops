# cloudify 系列实验共享环境 —— 被各实验主脚本 source（BASH_SOURCE[1] = 调用方实验目录）
#
# 约定：
#   - cfy 必须跑在 Python 3.11 venv（../.venv）；3.13 报 No module named 'cgi'
#   - CFY_WORKDIR 必须在蓝图目录之外（init 会整目录递归拷贝蓝图）
#   - 本地 CLI 不暴露 node-instances/nodes/events，实例级断言走 scripts/local_query.py 直读存储

_EXP_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
CFY_CLI="$_EXP_DIR/../.venv/bin/cfy"
CQ="$_EXP_DIR/../scripts/local_query.py"
export CFY_WORKDIR="${CFY_WORKDIR:-$HOME/.cfy-handson/$(basename "$_EXP_DIR")}"

# cfy_run <log-name> <cfy args...>：执行并留档（先落档再断言，不在活管道上 grep）
#   log-name 为裸名，落盘为 .logs/<name>.log
cfy_run() {
    local name="$1"; shift
    mkdir -p "$_EXP_DIR/.logs"
    "$CFY_CLI" "$@" 2>&1 | grep -vE "pkg_resources|import pkg" | tee "$_EXP_DIR/.logs/$name.log"
}

# alive_count <deployment-id>：本地存储中 state != deleted 的实例数
alive_count() {
    python3 "$CQ" "$CFY_WORKDIR" "$1" --alive | wc -l | tr -d ' '
}

# inst_attr <deployment-id> <runtime-prop>：打印拥有该属性的活跃实例的属性值
#   （滤掉无此属性实例的空行；配合 grep -c . 数实例数）
inst_attr() {
    python3 "$CQ" "$CFY_WORKDIR" "$1" --alive --attr "$2" | grep -v '^$' || true
}

reset_workdir() {
    rm -rf "$CFY_WORKDIR"
}
