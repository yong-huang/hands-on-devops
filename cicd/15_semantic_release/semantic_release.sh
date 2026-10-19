#!/usr/bin/env bash
# =============================================================================
# 15 · semantic-release 版本工程 — 主演示脚本
#
# 用法：
#   ./semantic_release.sh local        # 本地三组提交 dry-run：fix/feat/feat! 断言递升
#   ./semantic_release.sh real-setup   # 克隆真仓库，装 workflow + release 配置并推送
#   ./semantic_release.sh real-release # 四连发：feat→1.0.0 / fix→1.0.1 / feat→1.1.0 / feat!→2.0.0
#   ./semantic_release.sh real-verify  # gh api 断言 Release 存在、body 非空且含提交列表
#   ./semantic_release.sh clean        # 清 .tmp（真仓库上的 tag/Release 保留为实验证据）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

REPO_DIR=$PWD/.tmp/repo
REAL_DIR=$PWD/.tmp/real
TOOLS=$PWD/.tools
SEMR="$TOOLS/node_modules/.bin/semantic-release"
OWNER=yong-huang
REPO=cicd-lab

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# 本地玩具仓库：v1.0.0 起步，dry-run 断言三组递升规则 + chore 不发版
do_local() {
    step "local" "本地三组提交 dry-run：fix→patch / feat→minor / feat!→major"
    rm -rf .tmp && mkdir -p "${REPO_DIR}"
    cat > "${REPO_DIR}/release.local.js" << 'EOF'
// 本地 dry-run 配置：只做语义分析，不连 GitHub（真仓库版见 release.config.js）
module.exports = {
  // file:// URL：git ls-remote 离线可用，release-notes-generator 也要合法 URL
  repositoryUrl: "file://" + process.cwd(),
  tagFormat: "v${version}",
  plugins: [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
  ],
};
EOF
    ln -sfn "${TOOLS}/node_modules" "${REPO_DIR}/node_modules"   # 插件从 cwd 解析
    git -C "${REPO_DIR}" init -q
    git -C "${REPO_DIR}" config user.name probe
    git -C "${REPO_DIR}" config user.email p@t
    echo "# semrel toy" > "${REPO_DIR}/README.md"
    git -C "${REPO_DIR}" add -A
    git -C "${REPO_DIR}" commit -qm "feat: initial release api"
    git -C "${REPO_DIR}" tag v1.0.0

    # 场景跑法：追加提交 → dry-run → 提取 "Published release X.Y.Z"
    # $1=log $2=subject [$3=body]；major 必须用 BREAKING CHANGE footer
    # （semantic-release@24 的 analyzer 不认 "feat!:" 简写，见 README 踩坑）
    run_dry() {
        local log="$1" subject="$2" body="${3:-}"
        echo "$subject" >> "${REPO_DIR}/README.md"
        git -C "${REPO_DIR}" add -A
        if [ -n "${body}" ]; then
            git -C "${REPO_DIR}" commit -qm "${subject}" -m "${body}" --allow-empty
        else
            git -C "${REPO_DIR}" commit -qm "${subject}"
        fi
        ( cd "${REPO_DIR}" && "${SEMR}" --dry-run --no-ci -e ./release.local.js ) \
            > "${d}/${log}" 2>&1 || true
        grep -oE "Published release [0-9]+\.[0-9]+\.[0-9]+" \
            "${d}/${log}" | awk '{print $3}' || true
    }
    local d="${LOGS_LOCAL:-.logs}"
    mkdir -p "${d}"

    local v
    v="$(run_dry fix.log "fix: handle empty token")"
    [ "${v}" = "1.0.1" ] || { echo "        [!] fix 期望 1.0.1，实际 '${v}'" >&2; exit 1; }
    note "[ok] fix: → patch 1.0.1"

    v="$(run_dry feat.log "feat: add export endpoint")"
    [ "${v}" = "1.1.0" ] || { echo "        [!] feat 期望 1.1.0，实际 '${v}'" >&2; exit 1; }
    note "[ok] feat: → minor 1.1.0"

    v="$(run_dry major.log "feat: change auth header format" \
        "BREAKING CHANGE: auth header format is now Bearer-only")"
    [ "${v}" = "2.0.0" ] || { echo "        [!] feat! 期望 2.0.0，实际 '${v}'" >&2; exit 1; }
    note "[ok] feat!: → major 2.0.0"

    # dry-run 不会真打 tag——手动补 v2.0.0 基线，chore 才只看到自己
    git -C "${REPO_DIR}" tag v2.0.0
    v="$(run_dry chore.log "chore: docs only")"
    [ -z "${v}" ] || { echo "        [!] chore 不应发版，实际 '${v}'" >&2; exit 1; }
    grep -qi "no relevant changes" "${d}/chore.log" \
        || { echo "        [!] chore 应提示无相关变更" >&2; exit 1; }
    note "[ok] chore: → 不发版（no relevant changes）"
}

do_real_setup() {
    step "real-setup" "克隆 ${OWNER}/${REPO}，装 workflow + release 配置并推送"
    rm -rf "${REAL_DIR}"
    gh repo clone "${OWNER}/${REPO}" "${REAL_DIR}" -- --quiet
    cp release.config.js "${REAL_DIR}/release.config.js"
    mkdir -p "${REAL_DIR}/.github/workflows"
    cp .github/workflows/release.yml "${REAL_DIR}/.github/workflows/release.yml"
    gh auth setup-git >/dev/null 2>&1 || true
    git -C "${REAL_DIR}" add -A
    git -C "${REAL_DIR}" commit -qm "ci: add semantic-release workflow"
    git -C "${REAL_DIR}" push origin main >/dev/null
    note "[ok] workflow 与配置已推送（该 push 不含发布类提交，不会发版）"
}

# 发布一笔提交并等待对应 Release 出现（真仓库 main，首个发布固定 1.0.0）
release_one() {
    local msg="$1" expect="$2" body="${3:-}"
    echo "$msg" >> "${REAL_DIR}/RELEASE_NOTES.md"
    git -C "${REAL_DIR}" add -A
    if [ -n "${body}" ]; then
        git -C "${REAL_DIR}" commit -qm "${msg}" -m "${body}" --allow-empty
    else
        git -C "${REAL_DIR}" commit -qm "${msg}"
    fi
    git -C "${REAL_DIR}" push origin main >/dev/null
    local i
    for i in $(seq 1 60); do
        if gh api "repos/${OWNER}/${REPO}/releases/tags/v${expect}" >/dev/null 2>&1; then
            note "[ok] ${msg%%:*} → v${expect}（GitHub Release 已出现）"
            return 0
        fi
        sleep 5
    done
    echo "        [!] 等待 v${expect} 超时（5 分钟）" >&2
    return 1
}

do_real_release() {
    step "real-release" "真仓库四连发：首发 1.0.0 → fix 1.0.1 → feat 1.1.0 → feat! 2.0.0"
    release_one "feat: initial release api"   "1.0.0"
    release_one "fix: handle empty token"     "1.0.1"
    release_one "feat: add export endpoint"   "1.1.0"
    release_one "feat: change auth header format" "2.0.0" \
        "BREAKING CHANGE: auth header format is now Bearer-only"
}

do_real_verify() {
    step "real-verify" "gh api 断言：tag 齐全、body 非空且含对应提交列表"
    local tag body subject
    # changelog 按类型分组且剥掉前缀：断言匹配去前缀的提交主题
    for pair in "v1.0.0:initial release api" "v1.0.1:handle empty token" \
                "v1.1.0:add export endpoint" \
                "v2.0.0:change auth header format"; do
        tag="${pair%%:*}"
        subject="${pair#*:}"
        body="$(gh api "repos/${OWNER}/${REPO}/releases/tags/${tag}" --jq '.body')"
        [ -n "${body}" ] \
            || { echo "        [!] ${tag} 的 Release body 为空" >&2; exit 1; }
        echo "${body}" | grep -qF "${subject}" \
            || { echo "        [!] ${tag} 的 changelog 不含提交 '${subject}'" >&2; exit 1; }
        note "[ok] ${tag}：body 非空且含 '${subject}'"
    done
    local n
    n="$(gh api "repos/${OWNER}/${REPO}/releases" --jq 'length')"
    [ "${n}" -ge 4 ] || { echo "        [!] Release 数应 ≥4，实际 ${n}" >&2; exit 1; }
    note "[ok] 仓库现有 ${n} 个 Release——版本工程链路（commit→tag→release）全通"
}

do_clean() {
    step "clean" "清 .tmp（真仓库上的 tag/Release 保留为实验证据）"
    rm -rf .tmp
    note "[ok] .tmp 已清"
}

main() {
    local target="${1:-local}"
    case "${target}" in
        local)        do_local ;;
        real-setup)   do_real_setup ;;
        real-release) do_real_release ;;
        real-verify)  do_real_verify ;;
        clean)        do_clean ;;
        *) echo "可用: local | real-setup | real-release | real-verify | clean" >&2; exit 1 ;;
    esac
}
main "$@"
