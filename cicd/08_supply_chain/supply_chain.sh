#!/usr/bin/env bash
# =============================================================================
# 08 · 流水线供应链加固 — 主演示脚本
#
# 完整生命周期：dangerous → hardened → pin → clean
# 用法：
#   ./supply_chain.sh dangerous    # act 跑危险版（pull_request_target），取证
#   ./supply_chain.sh hardened     # act 跑加固版（最小权限 + SHA pin），断言
#   ./supply_chain.sh pin          # SHA pin 扫描（第三方 action 引用检查）
#   ./supply_chain.sh clean        # 清临时文件
#   ./supply_chain.sh              # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

IMG="catthehacker/ubuntu:act-latest"
LOGS=".logs"
ACT=(act --pull=false -P "ubuntu-latest=$IMG" --artifact-server-path "$LOGS/art" --action-offline-mode)

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# act 的 workspace 是 git 仓库根——实验目录内的 workflows 需要放进临时
# .github/workflows/ 结构再跑
setup_gh() {
    if [ -d .tmp/.github/workflows ]; then return 0; fi
    mkdir -p .tmp/.github/workflows
    cp workflows/01_dangerous.yml .tmp/.github/workflows/
    cp workflows/02_hardened.yml .tmp/.github/workflows/
    ( cd .tmp && git init -q && git config user.name probe && git config user.email p@t && git add -A && git commit -qm init )
}

# 跑一个 workflow 并留档
run_wf() {
    local f="$1" log="$2"
    ( cd .tmp && "${ACT[@]}" -W "$f" ) 2>&1 | tee "$LOGS/$log"
}

ensure_ready() {
    command -v act >/dev/null || { echo "需要 act：brew install act" >&2; exit 1; }
    command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }
    mkdir -p "$LOGS"
}

do_dangerous() {
    step "dangerous" "act 跑危险版（pull_request_target），取证宽权限执行"
    ensure_ready
    setup_gh
    # act 模拟 pull_request_target（用 -e 传入模拟 payload）
    cat > .tmp/pr-event.json << 'ENDJSON'
{
  "pull_request": {
    "head": { "sha": "abc123", "ref": "feature-branch" },
    "base": { "ref": "main" }
  },
  "action": "opened"
}
ENDJSON
    run_wf .github/workflows/01_dangerous.yml dangerous.log \
        -e PULL_REQUEST_TARGET_EVENT='{"action":"opened"}' \
        -e GITHUB_EVENT_PATH="$PWD/.tmp/pr-event.json" \
        || true   # 危险版可能失败（act 不完全支持 pr_target），取证即可
    if grep -q "DANGEROUS" "$LOGS/dangerous.log" 2>/dev/null; then
        note "[ok] 危险版执行取证：fork 代码在 base 权限上下文中运行"
    else
        note "[i] act 对 pull_request_target 支持有限——真仓库上 fork 代码会以 base 权限执行"
    fi
    # 不管 act 支不支持，取证 workflow 声明了宽权限
    grep -q "pull_request_target" .tmp/.github/workflows/01_dangerous.yml \
        || { echo "    [!] workflow 未声明 pull_request_target" >&2; exit 1; }
    grep -q "pull-requests: write" .tmp/.github/workflows/01_dangerous.yml \
        || { echo "    [!] workflow 未声明宽权限" >&2; exit 1; }
    note "[ok] 危险 workflow 声明取证：pull_request_target + pull-requests: write"
}

do_hardened() {
    step "hardened" "act 跑加固版（最小权限 + fork 隔离），断言 secrets 取不到"
    ensure_ready
    setup_gh
    run_wf .github/workflows/02_hardened.yml hardened.log
    grep -q "secrets 不可访问" "$LOGS/hardened.log" \
        || { echo "    [!] 加固版 secrets 隔离断言失败" >&2; exit 1; }
    grep -q "event: pull_request" "$LOGS/hardened.log" \
        || { echo "    [!] 未见 pull_request 事件（act 模拟）" >&2; exit 1; }
    note "[ok] 加固版：secrets 不可访问（fork PR 隔离生效）+ 最小权限"
}

do_pin() {
    step "pin" "SHA pin 扫描（第三方 action 引用检查）"
    # 扫描 workflows/ 目录（含危险版与加固版）
    python3 check_sha_pin.py workflows/
    # 扫描临时 .github/workflows/ 目录
    python3 check_sha_pin.py .tmp/.github/workflows/
}

do_clean() {
    step "clean" "清临时文件"
    rm -rf "$LOGS" .tmp
    note "[ok] .logs 与 .tmp 已清"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        dangerous) do_dangerous ;;
        hardened)  do_hardened ;;
        pin)       do_pin ;;
        clean)     do_clean ;;
        all)       do_dangerous; do_hardened; do_pin; do_clean ;;
        *) echo "可用: dangerous | hardened | pin | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
