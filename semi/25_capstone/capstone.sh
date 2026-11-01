#!/usr/bin/env bash
# semi/25_capstone · 🏁 终极串联：平台一键重建 + 12 条验收断言
# 用法：./capstone.sh bootstrap | accept | all
#   bootstrap  按序重放 01-24 的全部自动化（GitLab→组织/LFS→农场→流水线→度量），幂等可重入
#   accept     acceptance_suite/run_all.sh 12 条断言
#   all        bootstrap + accept（完整从零到验收）
set -uo pipefail
cd "$(dirname "$0")"

step() { echo; echo "=====> [$1] $2"; }

run_step() {
    local desc="$1"; shift
    step boot "$desc"
    if "$@"; then
        echo "  [ok]   完成"
    else
        echo "  [fail] 失败：$*"
        return 1
    fi
}

do_bootstrap() {
    step bootstrap "阶段一：平台（01-04）"
    (cd ../01_gitlab_up && ./gitlab_up.sh up)        || return 1
    (cd ../02_org_guard && ./org_guard.sh up)        || return 1
    (cd ../04_mr_gate && ./mr_gate.sh up)            || return 1

    step bootstrap "阶段二三：载体与农场（03/05/06/07）"
    (cd ../03_rtl_lfs && ./rtl_lfs.sh up)            || return 1
    (cd ../05_runner_farm && ./runner_farm.sh up)    || return 1
    (cd ../06_eda_image && ./eda_image.sh up)        || return 1
    (cd ../07_kind_farm && ./kind_farm.sh up)        || return 1

    step bootstrap "阶段四：回归农场（12-16，含矩阵/夜间/license/队列/仪表盘）"
    (cd ../12_seed_matrix && ./seed_matrix.sh up)    || return 1
    (cd ../13_nightly && ./nightly.sh up)            || return 1
    (cd ../14_license_gate && ./license_gate.sh up)  || return 1
    (cd ../15_queue_farm && ./queue_farm.sh up)      || return 1
    (cd ../16_dashboard && ./dashboard.sh up)        || return 1

    step bootstrap "阶段五：构建发布链（17/18/19/20）"
    (cd ../17_fpga && ./fpga.sh up)                  || return 1
    (cd ../18_artifacts && ./artifacts.sh up)        || return 1
    (cd ../19_release && ./release.sh up)            || return 1
    (cd ../20_full_chain && ./full_chain.sh up)      || return 1

    step bootstrap "阶段六：生产化（21/22/24）"
    (cd ../21_security && ./security.sh up)          || return 1
    (cd ../22_airgap && ./airgap.sh up)              || return 1
    (cd ../24_metrics && ./metrics.sh up)            || return 1
    echo
    echo "[ok] 全部自动化重放完成——进入验收"
}

do_accept() {
    step accept "12 条断言（acceptance_suite/run_all.sh）"
    bash acceptance_suite/run_all.sh
}

main() {
    local target="${1:-all}"
    case "${target}" in
        bootstrap) do_bootstrap ;;
        accept)    do_accept ;;
        all)       do_bootstrap && do_accept ;;
        *) echo "用法: $0 bootstrap | accept | all" >&2; exit 1 ;;
    esac
}
main "$@"
