#!/usr/bin/env bash
# =============================================================================
# 02 · 矩阵构建与并发治理 — 主演示脚本
#
# 完整生命周期：matrix → failfast → cloud → clean
# 用法：
#   ./matrix_concurrency.sh matrix    # act 跑矩阵展开，断言 6 个组合逐一在册
#   ./matrix_concurrency.sh failfast  # act 对比 fail-fast true/false 的中止行为
#   ./matrix_concurrency.sh cloud     # 真仓库验证 concurrency 取消（gh api 断言）
#   ./matrix_concurrency.sh clean     # 清日志与临时目录
#   ./matrix_concurrency.sh           # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

IMG="catthehacker/ubuntu:act-latest"
LOGS=".logs"
ART=".artifacts"
REPO="yong-huang/cicd-lab"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# 公共 act 参数：镜像钉死 + 离线 + macos 标签也映射到 Linux 容器（本地只验展开逻辑）
ACT=(act --pull=false -P "ubuntu-latest=$IMG" -P "macos-latest=$IMG" \
     --artifact-server-path "$ART" --action-offline-mode)

# run_wf <file> <logfile>：跑一个 workflow 留档；非零退出码透传（act 红 → 这里红）
run_wf() {
    local f="$1" log="$2"
    mkdir -p "$LOGS"
    "${ACT[@]}" -W "$f" 2>&1 | tee "$LOGS/$log"
}

ensure_ready() {
    command -v act >/dev/null || { echo "需要 act：brew install act" >&2; exit 1; }
    docker image inspect "$IMG" >/dev/null 2>&1 \
        || { echo "需要镜像 ${IMG}（act 首跑自动拉取）" >&2; exit 1; }
    command -v gh >/dev/null || { echo "需要 gh CLI：brew install gh" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "需要 gh auth login" >&2; exit 1; }
    mkdir -p "$LOGS"
}

# act 跑完整个 run 后，按 job 名逐个断言成功（矩阵每个组合都要在册）
assert_jobs() {
    local log="$1"; shift
    local job
    for job in "$@"; do
        grep -qE "▶ *$job|\\[$job *[a-z-]*\\].*Job succeeded|✓  Set up job.*$job" "$log" \
            && grep -q "Job succeeded" "$log" \
            || { echo "    [!] 未确认 job [$job] 成功，看 $log" >&2; exit 1; }
    done
}

do_matrix() {
    step "matrix" "act 跑矩阵展开：6 个组合逐一在册"
    ensure_ready
    run_wf workflows/01_matrix_basic.yml matrix.log
    local combo
    for combo in "ubuntu-latest node=18" "ubuntu-latest node=20" "ubuntu-latest node=22" \
                 "macos-latest node=20" "macos-latest node=22" "macos-latest node=18"; do
        # shellcheck disable=SC2076
        grep -q "$combo" "$LOGS/matrix.log" \
            || { echo "    [!] 矩阵组合缺失：$combo" >&2; exit 1; }
    done
    local n
    n=$(grep -c "experimental=" "$LOGS/matrix.log" || true)
    [ "$n" -eq 6 ] || { echo "    [!] 组合数=${n}，期望 6" >&2; exit 1; }
    grep -q "experimental=true" "$LOGS/matrix.log" \
        || { echo "    [!] include 补回的组合未带 experimental 标记" >&2; exit 1; }
    note "[ok] exclude 裁剪 + include 补回：6 个组合逐一在册（含 experimental 标记）"
}

do_failfast() {
    step "failfast" "本地验 fail-fast: false 语义；true 的取消语义推真仓库（act 模拟不了）"
    ensure_ready
    note "fail-fast: false——失败不传染，4 个组合全部跑完："
    local rc2=0
    run_wf workflows/03_failfast_false.yml failfast_false.log || rc2=$?
    [ "$rc2" -ne 0 ] || { echo "    [!] false：含 2 个必败组合竟然全绿" >&2; exit 1; }
    # act 怪癖：任一 matrix job 失败后，run 级结论把成功 job 也标 failed——
    # 所以断言用 step 级输出取证（done cleanly vs FAILED），job 结论留给真仓库
    local fails oks
    fails=$(grep -c "FAILED" "$LOGS/failfast_false.log" || true)
    oks=$(grep -c "done cleanly" "$LOGS/failfast_false.log" || true)
    [ "${fails}" -eq 2 ] && [ "${oks}" -eq 2 ] \
        || { echo "    [!] false：FAILED=${fails} done=${oks}，期望 2+2" >&2; exit 1; }
    note "[ok] false：4 个组合全部跑完（2 FAILED + 2 done cleanly，失败不传染）"
    note "[ok] true 的取消语义为 GitHub 服务端行为，由 cloud 段推真仓库取证"
}

do_cloud() {
    step "cloud" "真仓库验证：fail-fast 取消差异 + concurrency 取消（gh api 断言）"
    ensure_ready
    note "公共仓库 ${REPO}（免费额度；清单既定的真仓库验证环节）"
    if gh repo view "$REPO" >/dev/null 2>&1; then
        note "仓库已存在，复用"
    else
        gh repo create "$REPO" --public --description "CI/CD 学习实验：矩阵与并发治理（清单项目 02）" >/dev/null
        note "已创建公共仓库 $REPO"
    fi
    local ws="" total done_count
    # 跳过判定按目标 workflow 自己的 run 数——全仓库 run 总数会被其他
    # 实验撑大，导致推送被跳过、concurrency run 根本不存在
    total=$(gh api "repos/$REPO/actions/runs?per_page=40" \
        --jq '[.workflow_runs[] | select(.name=="concurrency-demo")] | length' 2>/dev/null || echo 0)
    if [ "${total:-0}" -ge 3 ]; then
        note "concurrency-demo 已有 ${total} 个 run（上次推送的产物），跳过推送直接取证"
    else
        ws=$(mktemp -d)
        git clone --quiet "https://github.com/$REPO.git" "$ws" \
            || { echo "    [!] git 网络不通但 gh api 可用，稍后重试" >&2; exit 1; }
        ( cd "$ws"
          git config user.name "cicd-lab"; git config user.email "cicd-lab@example.com"
          mkdir -p .github/workflows
          cp "$OLDPWD"/workflows/02_failfast_true.yml    .github/workflows/failfast-true.yml
          cp "$OLDPWD"/workflows/03_failfast_false.yml   .github/workflows/failfast-false.yml
          cp "$OLDPWD"/workflows/04_concurrency_cloud.yml .github/workflows/concurrency-demo.yml
          git add -A && git commit -qm "feat: fail-fast 对比与 concurrency 演示" --allow-empty
          # 多实验共写 main：push 前先 rebase，失败重试（非 fast-forward 静默丢推送的教训）
          robust_push() {
              local a
              for a in 1 2 3; do
                  git pull --rebase -q origin main 2>/dev/null || true
                  git push -q origin HEAD:main 2>/dev/null && return 0
                  sleep 5
              done
              echo "    [!] push 重试耗尽" >&2; return 1
          }
          robust_push
          note "三个 workflow 已推送"
          sleep 8
          git commit -q --allow-empty -m "chore: trigger second run（同 group 应取消前一个）"
          robust_push
          note "第二次推送完成（concurrency group 应取消旧 run）"
        )
    fi
    note "轮询 GitHub API 等全部 run 落定（最多 6 分钟；fail-fast 2 分钟 + concurrency sleep 90s）"
    local i=0 done_count=0
    while [ "$i" -lt 180 ]; do
        done_count=$(gh api "repos/$REPO/actions/runs?per_page=40" \
            --jq '[.workflow_runs[] | select(.status=="completed")] | length' 2>/dev/null || echo 0)
        total=$(gh api "repos/$REPO/actions/runs?per_page=40" --jq '.total_count // 0' 2>/dev/null || echo 0)
        [ "${total:-0}" -ge 6 ] && [ "${done_count:-0}" -ge 6 ] && break
        i=$((i+1)); sleep 2
    done
    gh api "repos/$REPO/actions/runs?per_page=40" \
        --jq '.workflow_runs[] | "\(.name)  \(.status)/\(.conclusion)"' | sort | sed 's/^/        /' \
        | tee "$LOGS/cloud-runs.txt"

    note "断言 1：concurrency-demo 第一次 run 被 cancelled（轮询 180s 等传播）"
    local conc_cancel=0 w
    for w in $(seq 1 36); do
        conc_cancel=$(gh api "repos/$REPO/actions/runs?per_page=40" \
            --jq '[.workflow_runs[] | select(.name=="concurrency-demo" and .conclusion=="cancelled")] | length')
        [ "${conc_cancel}" -ge 1 ] && break
        sleep 5
    done
    [ "${conc_cancel}" -ge 1 ] \
        || { echo "    [!] concurrency 取消未生效（cancelled 数=${conc_cancel}）" >&2; exit 1; }
    note "[ok] concurrency group 生效：同组连推，旧 run 被 cancelled"

    note "断言 2：fail-fast true 有被取消的 job；false 无取消（全部跑完各自定论）"
    local true_run false_run t_cancel t_fail f_cancel f_ok
    true_run=$(gh api "repos/$REPO/actions/runs?per_page=40" \
        --jq '[.workflow_runs[] | select(.name=="failfast-true")][0].id')
    false_run=$(gh api "repos/$REPO/actions/runs?per_page=40" \
        --jq '[.workflow_runs[] | select(.name=="failfast-false")][0].id')
    # 等 run 跑完再取样——在途 run 的取消 job 尚未产生
    local i=0 st=""
    for i in $(seq 1 36); do
        st=$(gh api "repos/$REPO/actions/runs/$true_run" --jq '.status' 2>/dev/null || echo "")
        [ "${st}" = "completed" ] && break
        sleep 5
    done
    t_cancel=$(gh api "repos/$REPO/actions/runs/$true_run/jobs" \
        --jq '[.jobs[] | select(.conclusion=="cancelled")] | length')
    t_fail=$(gh api "repos/$REPO/actions/runs/$true_run/jobs" \
        --jq '[.jobs[] | select(.conclusion=="failure")] | length')
    f_cancel=$(gh api "repos/$REPO/actions/runs/$false_run/jobs" \
        --jq '[.jobs[] | select(.conclusion=="cancelled")] | length')
    f_ok=$(gh api "repos/$REPO/actions/runs/$false_run/jobs" \
        --jq '[.jobs[] | select(.conclusion=="success")] | length')
    note "        true: failure=${t_fail} cancelled=${t_cancel}；false: success=${f_ok} failure=2 cancelled=${f_cancel}"
    [ "${t_cancel:-0}" -ge 1 ] \
        || { echo "    [!] true：未见取消的 job（act 差异取证成功，服务端应 cancel）" >&2; exit 1; }
    [ "${f_cancel:-0}" -eq 0 ] \
        || { echo "    [!] false：不应有取消的 job" >&2; exit 1; }
    [ "${f_ok:-0}" -eq 2 ] \
        || { echo "    [!] false：成功 job 数=${f_ok}，期望 2" >&2; exit 1; }
    note "[ok] fail-fast 两种取值的中止行为差异已取证（服务端语义）"
    rm -rf "$ws"
}

do_clean() {
    step "clean" "清日志、制品与临时目录"
    rm -rf "$LOGS" "$ART"
    note "[ok] $LOGS 与 $ART 已清（job 容器由 act 自动回收，真仓库保留作学习资产）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        matrix)   do_matrix ;;
        failfast) do_failfast ;;
        cloud)    do_cloud ;;
        clean)    do_clean ;;
        all)      do_matrix; do_failfast; do_cloud; do_clean ;;
        *) echo "可用: matrix | failfast | cloud | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
