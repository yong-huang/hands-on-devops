#!/usr/bin/env bash
# =============================================================================
# 14 · flaky test 治理 — 主演示脚本
#
# 完整生命周期：detect → report → quarantine → broken → clean
# 用法：
#   ./flaky_pipeline.sh detect      # 10 轮 × reruns=3 跑测试集，观察随机失败
#   ./flaky_pipeline.sh report      # 解析重试证据 → flaky 报告 + 隔离名单
#   ./flaky_pipeline.sh quarantine  # 名单生效：10 轮全绿断言
#   ./flaky_pipeline.sh broken      # 真失败用例：重试 3 次仍红，退出码断言
#   ./flaky_pipeline.sh clean       # 清日志
#   ./flaky_pipeline.sh             # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

LOGS=.logs
ROUNDS=10
RERUNS=3

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# 单轮检测：稳定集 + flaky 集，reruns=N；红/绿都记录（观察模式）
detect_round() {
    local i="$1"
    local ec=0
    pytest tests/test_stable.py tests/test_flaky.py \
        --reruns "${RERUNS}" -q --tb=no -rR > "${LOGS}/detect-${i}.log" 2>&1 || ec=$?
    echo "${ec}"
}

do_detect() {
    step "detect" "${ROUNDS} 轮 × reruns=${RERUNS}：观察随机失败的真面目"
    mkdir -p "${LOGS}"
    local i ec red=0 rerun=0
    for i in $(seq 1 "${ROUNDS}"); do
        ec="$(detect_round "${i}")"
        if [ "${ec}" != "0" ]; then
            red=$((red + 1))
            note "第 ${i} 轮：红（重试耗尽仍失败）"
        elif grep -q "RERUN" "${LOGS}/detect-${i}.log"; then
            note "第 ${i} 轮：绿，但发生了重试（flaky 被掩盖）"
            rerun=$((rerun + 1))
        else
            note "第 ${i} 轮：绿（一次通过）"
        fi
    done
    [ "${rerun}" -gt 0 ] || [ "${red}" -gt 0 ] \
        || { echo "        [!] 10 轮无任何重试证据——随机注入未生效？" >&2; exit 1; }
    note "[ok] 检测完成：${rerun} 轮重试掩盖、${red} 轮重试耗尽仍红"
}

do_report() {
    step "report" "解析重试证据 → flaky 报告 + 隔离名单"
    python3 flaky_report.py "${LOGS}" "${ROUNDS}"
    local q="${LOGS}/quarantine.txt"
    [ -s "${q}" ] || { echo "        [!] 隔离名单为空" >&2; exit 1; }
    grep -q "test_flaky" "${q}" \
        || { echo "        [!] 名单里应只有 flaky 用例，见 ${q}" >&2; exit 1; }
    if grep -qv "^tests/test_flaky" "${q}"; then
        echo "        [!] 名单混入了非 flaky 用例" >&2; exit 1
    fi
    note "[ok] 隔离名单 quarantine.txt 已生成（$(wc -l < "${q}" | tr -d ' ') 条，全部指向 flaky）"
}

do_quarantine() {
    step "quarantine" "名单生效：deselect 隔离用例，${ROUNDS} 轮全绿断言"
    local deSel=""
    while IFS= read -r node; do
        deSel="${deSel} --deselect=${node}"
    done < "${LOGS}/quarantine.txt"
    local i ec=0
    for i in $(seq 1 "${ROUNDS}"); do
        pytest tests/test_stable.py tests/test_flaky.py \
            ${deSel} -q --tb=no > "${LOGS}/quarantine-${i}.log" 2>&1 || ec=$((ec + 1))
    done
    [ "${ec}" = "0" ] \
        || { echo "        [!] 隔离后仍有 ${ec} 轮红——隔离名单未生效" >&2; exit 1; }
    note "[ok] 隔离后 ${ROUNDS}/${ROUNDS} 轮全绿——flaky 不再劫持流水线"
}

do_broken() {
    step "broken" "真失败不误放行：恒错用例重试 ${RERUNS} 次仍红"
    local ec=0
    pytest tests/test_broken.py --reruns "${RERUNS}" -q --tb=line -rR \
        > "${LOGS}/broken.log" 2>&1 || ec=$?
    [ "${ec}" = "1" ] \
        || { echo "        [!] 真失败用例退出码应为 1，实际 ${ec}——流水线会误放行" >&2; exit 1; }
    local n
    n="$(grep -c "RERUN" "${LOGS}/broken.log" || true)"
    [ "${n}" = "${RERUNS}" ] \
        || { echo "        [!] 真失败应重试 ${RERUNS} 次，实际 RERUN × ${n}" >&2; exit 1; }
    note "[ok] 重试 ${n} 次仍红 + 退出码 1——重试机制对真失败无能为力（正确行为）"
}

do_clean() {
    step "clean" "清日志"
    rm -rf "${LOGS}"
    note "[ok] .logs 已清"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        detect)     do_detect ;;
        report)     do_report ;;
        quarantine) do_quarantine ;;
        broken)     do_broken ;;
        clean)      do_clean ;;
        all)        do_detect; do_report; do_quarantine; do_broken; do_clean ;;
        *) echo "可用: detect | report | quarantine | broken | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
