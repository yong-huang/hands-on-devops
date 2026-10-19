#!/usr/bin/env bash
# =============================================================================
# 13 · monorepo 增量构建 — 主演示脚本
#
# 完整生命周期：bootstrap → scenario-a → scenario-common → scenario-none → clean
# 用法：
#   ./monorepo_pipeline.sh bootstrap        # 建仓 + 首次全量构建，写下 .last-built
#   ./monorepo_pipeline.sh scenario-a       # 只改模块 A：断言 B/C 被 skip
#   ./monorepo_pipeline.sh scenario-common  # 改共享库：断言 A/B/C 全构建
#   ./monorepo_pipeline.sh scenario-none    # 无变更重推：断言全 skip（幂等）
#   ./monorepo_pipeline.sh clean            # 清临时仓库与日志
#   ./monorepo_pipeline.sh                  # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

IMG="catthehacker/ubuntu:act-latest"
LOGS=.logs
REPO=.tmp/repo
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
ACT=(act --pull=false --bind -P "ubuntu-latest=${IMG}" --artifact-server-path "$PWD/${LOGS}/art" --action-offline-mode)

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# 在临时仓库里跑一次流水线并留档
run_ci() {
    local log="$1"
    ( cd "${REPO}" && "${ACT[@]}" -W .github/workflows/ci.yml ) 2>&1 | tee "${LOGS}/${log}"
}

# 模块 $1 的构建 job 在日志里确实跑了
assert_built() {
    local log="$1" m="$2"
    grep -q "\[${m}\] build ok" "${LOGS}/${log}" \
        || { echo "        [!] ${m} 应构建但未见 build ok" >&2; exit 1; }
    note "[ok] ${m} 构建执行"
}

# 产物快照：跑流水线前留哈希，skip 断言用（产物未动 = job 没跑的铁证）
snap_artifacts() {
    : > "${LOGS}/art.hash"
    local f
    for f in "${REPO}"/artifacts/*.txt; do
        echo "$(git -C "${REPO}" hash-object "artifacts/$(basename "$f")") $(basename "$f")" >> "${LOGS}/art.hash"
    done
}

# 模块 $1 被 skip 的三重证据：无构建输出、日志零行、产物字节未动。
# act 0.2.89 对 if=false 的 job 完全静默——真仓库上这些 job 的 conclusion
# 是 "skipped"（run 元数据可见），本地以零执行证据代替（诚实预期已注明）。
assert_skipped() {
    local log="$1" m="$2"
    grep -q "\[${m}\] build ok" "${LOGS}/${log}" \
        && { echo "        [!] ${m} 应 skip 却跑了构建" >&2; exit 1; }
    local n
    n="$(grep -c "build-${m}" "${LOGS}/${log}" || true)"
    [ "${n}" = "0" ] \
        || { echo "        [!] ${m} 的 job 出现 ${n} 行日志——不是 skip" >&2; exit 1; }
    local want got
    want="$(grep " ${m}\.txt$" "${LOGS}/art.hash" | awk '{print $1}')"
    got="$(git -C "${REPO}" hash-object "artifacts/${m}.txt" 2>/dev/null || echo missing)"
    [ -n "${want}" ] && [ "${want}" = "${got}" ] \
        || { echo "        [!] ${m} 产物被更新——不是 skip" >&2; exit 1; }
    note "[ok] ${m} 被 skip（日志零行 + 无构建输出 + 产物未动）"
}

# affected job 打出的模块清单断言（清单含 []，必须固定串匹配而非正则）
assert_affected() {
    local log="$1" want="$2"
    grep -qF "affected=${want}" "${LOGS}/${log}" \
        || { echo "        [!] affected 期望 ${want}，见日志" >&2; exit 1; }
    note "[ok] affected 检测 = ${want}"
}

mark_built() {
    git -C "${REPO}" rev-parse HEAD > "${REPO}/.last-built"
}

do_bootstrap() {
    step "bootstrap" "建仓 + 首次全量构建（无 .last-built → 空树基准 → 全构建）"
    mkdir -p "${LOGS}"
    rm -rf .tmp && mkdir -p .tmp
    cp -R monorepo "${REPO}"
    git -C "${REPO}" init -q
    git -C "${REPO}" config user.name probe
    git -C "${REPO}" config user.email p@t
    git -C "${REPO}" add -A
    git -C "${REPO}" commit -qm "initial: 3 modules + common lib"
    run_ci bootstrap.log
    assert_affected bootstrap.log '["a","b","c"]'
    assert_built bootstrap.log a
    assert_built bootstrap.log b
    assert_built bootstrap.log c
    mark_built
    note "[ok] 首次全量完成，.last-built 已指向 HEAD"
}

do_scenario_a() {
    step "scenario-a" "只改模块 A：断言 affected=[\"a\"] 且 B/C 被 skip"
    echo "src of a v2" > "${REPO}/apps/a/src.txt"
    git -C "${REPO}" add -A
    git -C "${REPO}" commit -qm "change a only"
    snap_artifacts
    run_ci scenario-a.log
    assert_affected scenario-a.log '["a"]'
    assert_built scenario-a.log a
    assert_skipped scenario-a.log b
    assert_skipped scenario-a.log c
    mark_built
    note "[ok] 单模块变更只触发自身——B/C 一个请求都没跑"
}

do_scenario_common() {
    step "scenario-common" "改共享库：断言 affected=[\"a\", \"b\", \"c\"] 全构建（扇出）"
    sed -i '' 's/common-lib v1/common-lib v2/' "${REPO}/libs/common/common.sh"
    git -C "${REPO}" add -A
    git -C "${REPO}" commit -qm "bump common lib to v2"
    snap_artifacts
    run_ci scenario-common.log
    assert_affected scenario-common.log '["a","b","c"]'
    assert_built scenario-common.log a
    assert_built scenario-common.log b
    assert_built scenario-common.log c
    mark_built
    note "[ok] 共享库变更扇出到全部依赖它的模块"
}

do_scenario_none() {
    step "scenario-none" "无变更重推：断言全 skip（幂等）"
    local before
    before="$(cat "${REPO}/artifacts/a.txt" "${REPO}/artifacts/b.txt" "${REPO}/artifacts/c.txt" | git hash-object --stdin)"
    snap_artifacts
    run_ci scenario-none.log
    assert_affected scenario-none.log '[]'
    assert_skipped scenario-none.log a
    assert_skipped scenario-none.log b
    assert_skipped scenario-none.log c
    local after
    after="$(cat "${REPO}/artifacts/a.txt" "${REPO}/artifacts/b.txt" "${REPO}/artifacts/c.txt" | git hash-object --stdin)"
    [ "${before}" = "${after}" ] \
        || { echo "        [!] 无变更重推却更新了构建产物" >&2; exit 1; }
    note "[ok] 产物字节级未动——重复触发零成本"
}

do_clean() {
    step "clean" "清临时仓库与日志"
    rm -rf .tmp "${LOGS}"
    note "[ok] .tmp 与 .logs 已清"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        bootstrap)       do_bootstrap ;;
        scenario-a)      do_scenario_a ;;
        scenario-common) do_scenario_common ;;
        scenario-none)   do_scenario_none ;;
        clean)           do_clean ;;
        all)             do_bootstrap; do_scenario_a; do_scenario_common; do_scenario_none; do_clean ;;
        *) echo "可用: bootstrap | scenario-a | scenario-common | scenario-none | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
