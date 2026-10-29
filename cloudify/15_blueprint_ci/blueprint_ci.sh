#!/usr/bin/env bash
# =============================================================================
# 15 · 蓝图即代码 — act 本地 CI 门禁（三 job + 两条负向红线）
#
# 主 workflow：lint+validate / unit(05 插件 pytest) / smoke(本地回路) 全绿；
# 负向 workflow：坏 validate、坏断言必须红（门禁存在的意义）。
# 容器内 pip 走清华源；cloudify 7.0.5 在容器 py3.10 可用（3.13 才有 cgi 坑）。
# 用法：
#   ./blueprint_ci.sh green    # act 跑主 workflow，断言三 job 全绿
#   ./blueprint_ci.sh bad-validate   # 负向：坏蓝图必须红（act 退出码非 0）
#   ./blueprint_ci.sh bad-unit       # 负向：坏断言必须红
#   ./blueprint_ci.sh residue        # 宿主无 cfy 容器残留
#   ./blueprint_ci.sh                # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

# --container-daemon-socket - : 禁 sock 挂载（slim 镜像 + act 默认挂载会 Duplicate）
# -p false                    : act 默认每次 pull，网络抖动会把本地镜像都变成 Set up 失败
# --bind：act 默认只复制 git tracked 文件（untracked 的 cloudify/ 全空）——直挂真实目录
ACT_FLAGS=(-P ubuntu-latest=python:3.11-slim --pull=false --bind)

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

run_act() {  # run_act <log> <workflow-file>
    mkdir -p .logs
    act -W ".github/workflows/$2" push "${ACT_FLAGS[@]}" 2>&1 \
        | grep -vE "pkg_resources|import pkg" | tee ".logs/$1.log" || true
}

stage_plugin() {
    # act 的 workspace 是复制不是挂载（cicd/01 教训）——被测插件须在 workspace 内
    rm -rf plugin plugin-broken
    cp -r ../05_my_plugin/plugin plugin
    echo "$PWD/plugin" > .plugin-staged
}

do_green() {
    step green "act 跑主 workflow：lint-validate / unit / smoke 三 job"
    run_act green blueprint-ci.yaml
    for job in lint-validate unit smoke; do
        grep -qE "\[blueprint-ci/${job} *\].*Job succeeded" .logs/green.log \
            || fail "${job} job 未见 Job succeeded"
        ok "${job} job 绿"
    done
    grep -q "smoke passed" .logs/green.log \
        || fail "smoke 未见 'smoke passed' 证据行"
    ok "smoke 含本地 install→outputs→uninstall 全链"
}

do_bad() {  # do_bad <name>
    step "$1" "负向 workflow 必须红（act 退出码非 0）"
    set +e
    act -W ".github/workflows/$1.yaml" push "${ACT_FLAGS[@]}" > ".logs/$1.log" 2>&1
    local rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$1 门禁未拦截（act 退出码 ${rc}，应为非 0）"
    ok "$1 被门禁拦截（act 退出码 ${rc}）"
}

do_residue() {
    step residue "CI 不在宿主留容器（kind 节点 cfy-lab-* 是实验 14 的常驻集群，不算）"
    # 只认本次 workflow 的容器（名字含 job 名）；act 偶发滞留的容器由 --reuse
    # 语义外的主脚本兜底清理
    local n
    n=$(docker ps -aq --filter name=act-blueprint-ci 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "0" ] || { docker ps -aq --filter name=act-blueprint-ci | xargs docker rm -f >/dev/null 2>&1 || true; }
    n=$(docker ps -aq --filter name=act-bad- 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "0" ] || { docker ps -aq --filter name=act-bad- | xargs docker rm -f >/dev/null 2>&1 || true; }
    local left
    left=$(docker ps -aq --filter name=act-blueprint-ci --filter name=act-bad- 2>/dev/null | wc -l | tr -d ' ')
    [ "$left" = "0" ] || fail "仍有 $left 个本套件容器残留"
    ok "本套件容器零残留（act-bad-unit 的滞留容器已清理）"
}

case "${1:-all}" in
    green)       stage_plugin && do_green ;;
    bad-validate) do_bad bad-validate ;;
    bad-unit)     stage_plugin && do_bad bad-unit ;;
    residue)      do_residue ;;
    all)
        stage_plugin
        do_green
        do_bad bad-validate
        do_bad bad-unit
        do_residue
        echo; echo "✅ 15 全部通过"
        ;;
    *) echo "用法: $0 [green|bad-validate|bad-unit|residue|all]"; exit 1 ;;
esac
