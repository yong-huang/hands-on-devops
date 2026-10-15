#!/usr/bin/env bash
# =============================================================================
# 06 · 给 IaC 写测试（Mocks 单测 + CrossGuard 策略）— 主演示脚本
#
# 本实验全程止步 preview，不创建任何真实资源——测的是声明与规范，不是运行时。
# 完整生命周期：test → policy → evil → clean
# 用法：
#   ./policy_test.sh test    # npm test：mocks 单测全绿（断言资源属性）
#   ./policy_test.sh policy  # 合规配置过 preview 策略门禁（绿）
#   ./policy_test.sh evil    # 故意违规：latest 镜像 + 丢标签 → 门禁拦截（红）
#   ./policy_test.sh clean   # 清空栈与日志，零残留
#   ./policy_test.sh         # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# preview 同样要实例化 provider 插件，统一走 docker-env.sh 选 socket
. "../../scripts/docker-env.sh"

export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1

PU="pulumi -C program"
LOGS=".logs"
POLICY="$PWD/policy"   # --policy-pack 的相对路径相对 -C program 解析，必须给绝对路径

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# run <name> <pulumi 子命令...>：执行并留档；允许失败时调用方接 || true
run() {
    local name="$1"; shift
    mkdir -p "$LOGS"
    $PU "$@" 2>&1 | tee "$LOGS/$name.log"
}

ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    if [ ! -d program/node_modules ]; then
        note "首次运行：安装 TS 依赖（npm install，约 1 分钟）"
        (cd program && npm install --loglevel=error)
    fi
    if [ ! -d policy/node_modules ]; then
        note "首次运行：安装策略包依赖（npm install）"
        (cd policy && npm install --loglevel=error)
    fi
    mkdir -p .pulumi-state
}

ensure_stack() {
    if ! $PU stack select dev >/dev/null 2>&1; then
        $PU stack init dev >/dev/null
        note "已创建栈 dev"
    fi
    $PU config set evil false --stack dev >/dev/null
    $PU config set port 28501 --stack dev >/dev/null
}

do_test() {
    step "test" "npm test：mocks 单测——不需要 Docker 在跑"
    ensure_ready
    mkdir -p "$LOGS"
    (cd program && npm test) 2>&1 | tee "$LOGS/npm-test.log"
    grep -q "passing" "$LOGS/npm-test.log" \
        || { echo "    [!] 未见 passing 统计" >&2; exit 1; }
    local n
    n=$(grep -oE "^\s+[0-9]+ passing" "$LOGS/npm-test.log" | grep -oE "[0-9]+" | head -1)
    [ "${n:-0}" -ge 4 ] \
        || { echo "    [!] 断言数量不足（$n 个），非空跑才算测试" >&2; exit 1; }
    note "[ok] ${n} 个断言全绿：镜像/端口/标签/URN 都是程序声明的真实检查"
}

do_policy() {
    step "policy" "合规配置过 preview 策略门禁（绿）"
    ensure_ready
    ensure_stack
    run preview-good preview --stack dev --policy-pack "$POLICY"
    grep -qi "violation" "$LOGS/preview-good.log" \
        && { echo "    [!] 合规配置竟有违规" >&2; exit 1; }
    grep -q "✅ pulumi06@" "$LOGS/preview-good.log" \
        || { echo "    [!] 未见策略包生效痕迹（应打印 Policies 行）" >&2; exit 1; }
    note "[ok] 策略包体检通过（Policies 行 ✅），preview 正常给出计划"
}

do_evil() {
    step "evil" "故意违规：latest 镜像 + 丢标签 → 门禁拦截（红）"
    $PU config set evil true --stack dev >/dev/null
    local rc=0
    run preview-evil preview --stack dev --policy-pack "$POLICY" || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "    [!] 违规配置竟然过了 mandatory 门禁" >&2; exit 1
    fi
    grep -q "no-latest-image" "$LOGS/preview-evil.log" \
        || { echo "    [!] 未见 no-latest-image 拦截" >&2; exit 1; }
    grep -q "required-labels" "$LOGS/preview-evil.log" \
        || { echo "    [!] 未见 required-labels 拦截" >&2; exit 1; }
    note "[ok] preview 退出码 ${rc}（非 0）：两条 mandatory 策略双双拦截"
    note "拦截详情（节选）："
    grep -B1 -A2 "no-latest-image\|required-labels" "$LOGS/preview-evil.log" \
        | head -14 | sed 's/^/        /'
    $PU config set evil false --stack dev >/dev/null
    note "evil 配置已还原为 false（期望态回到合规版本）"
}

do_clean() {
    step "clean" "清空栈与日志（本实验从未创建真实资源）"
    if $PU stack select dev >/dev/null 2>&1; then
        $PU stack rm dev --yes >/dev/null
        note "[ok] 空栈 dev 已移除（preview-only 实验，无资源可 destroy）"
    fi
    rm -rf "$LOGS"
    note "[ok] 日志已清；config 随栈删除；state 目录与源码保留"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        test)   do_test ;;
        policy) do_policy ;;
        evil)   do_evil ;;
        clean)  do_clean ;;
        all)    do_test; do_policy; do_evil; do_clean ;;
        *) echo "可用: test | policy | evil | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
