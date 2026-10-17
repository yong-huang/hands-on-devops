#!/usr/bin/env bash
# =============================================================================
# 06 · Environments 部署保护与审批流 — 主演示脚本
#
# 完整生命周期：setup → trigger → assert-pending → approve → assert-done → clean
# 用法：
#   ./environments.sh setup          # 创建 environment + protection rule + 推 workflow
#   ./environments.sh trigger        # 触发 deploy（应卡 pending）
#   ./environments.sh assert-pending # 断言 job 卡在 waiting
#   ./environments.sh approve        # 审批放行
#   ./environments.sh assert-done    # 断言 job succeeded + 状态历史完整
#   ./environments.sh clean          # 删 environment + runner（可选）
#   ./environments.sh                # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

REPO="yong-huang/cicd-lab"
ENV_NAME="production"
LOGS=".logs"
WF_NAME="deploy-with-approval"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

ensure_ready() {
    command -v gh >/dev/null || { echo "需要 gh CLI" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "需要 gh auth login" >&2; exit 1; }
    gh repo view "$REPO" >/dev/null 2>&1 \
        || { echo "仓库 $REPO 不存在" >&2; exit 1; }
    mkdir -p "$LOGS"
}

# gh api 调用封装：留档 + 非 2xx 时报错退出
api() {
    local method="$1" path="$2" log="$3"
    shift 3
    local out
    if [ "$method" = "GET" ]; then
        out=$(gh api "$path" "$@")
    else
        out=$(gh api "$path" --method "$method" "$@")
    fi
    echo "$out" | tee "$LOGS/$log"
}

do_setup() {
    step "setup" "创建 environment（production）+ protection rule + 推 workflow"
    ensure_ready

    # 创建 environment + required reviewers（用当前认证用户作为审批人）
    local user
    user=$(gh api user --jq '.login')
    note "创建 environment ${ENV_NAME}（required reviewer: ${user}）"
    gh api "repos/$REPO/environments/${ENV_NAME}" \
        --method PUT \
        --input - <<ENDJSON 2>&1 | tee "$LOGS/setup-env.log" | head -3
{"can_admins_bypass": false, "reviewers": [{"type": "User", "id": $(gh api user --jq '.id')}]}
ENDJSON

    # 推 workflow 到仓库（用 gh api 直接创建文件，绕过 git push 网络问题）
    note "推 workflow 到 $REPO"
    local content
    content=$(base64 < workflows/deploy-approval.yml)
    gh api "repos/$REPO/contents/.github/workflows/deploy-approval.yml" \
        --method PUT \
        --input - <<ENDJSON 2>&1 | tee "$LOGS/setup-wf.log" | head -3
{"message": "feat: deploy with approval", "content": "$content"}
ENDJSON
    note "[ok] environment 与 workflow 已就绪"
}

do_trigger() {
    step "trigger" "触发 deploy（空 commit 推送 → workflow 应卡 pending）"
    # 用 gh api 的 contents API 创建空 commit
    local sha
    sha=$(gh api "repos/$REPO/commits/main" --jq '.sha')
    local tree
    tree=$(gh api "repos/$REPO/git/commits/$sha" --jq '.tree.sha')
    local new_commit
    new_commit=$(gh api "repos/$REPO/git/commits" \
        --method PUT \
        --input - <<ENDJSON --jq '.sha'
{"message": "chore: trigger deploy", "tree": "$tree", "parents": ["$sha"]}
ENDJSON
    )
    gh api "repos/$REPO/git/refs/heads/main" \
        --method PATCH \
        --input - <<ENDJSON >/dev/null
{"sha": "$new_commit"}
ENDJSON
    note "[ok] 空 commit 已推送，workflow 触发中"
    sleep 10
}

do_assert_pending() {
    step "assert-pending" "断言 job 卡在 waiting（环境审批门拦截）"
    local run_id
    run_id=$(gh api "repos/$REPO/actions/runs?per_page=1" \
        --jq '.workflow_runs[0].id')
    note "run_id=$run_id"
    local i=0 job_state=""
    while [ "$i" -lt 60 ]; do
        job_state=$(gh api "repos/$REPO/actions/runs/$run_id/jobs" \
            --jq '.jobs[0].status' 2>/dev/null || echo "unknown")
        case "$job_state" in
            waiting|queued) break ;;
        esac
        i=$((i+1)); sleep 3
    done
    note "job status: $job_state"
    [ "$job_state" = "waiting" ] || [ "$job_state" = "queued" ] \
        || { echo "    [!] job 未卡 pending（state=$job_state）" >&2; exit 1; }
    # 获取 pending deployment ID（approve 时需要）
    local pending
    pending=$(gh api "repos/$REPO/actions/runs/$run_id/pending_deployments" 2>/dev/null)
    echo "$pending" > "$LOGS/pending-deployment.json"
    note "pending deployment: $(echo "$pending" | head -c 200)"
    note "[ok] 环境审批门拦截成功：job 卡在 $job_state"
}

do_approve() {
    step "approve" "审批放行"
    local run_id
    run_id=$(gh api "repos/${REPO}/actions/runs?per_page=10" \
        --jq "[.workflow_runs[] | select(.name==\"${WF_NAME}\")][0].id")
    local pending_id
    pending_id=$(gh api "repos/$REPO/actions/runs/$run_id/pending_deployments" \
        --jq '.[0].id')
    local user_id
    user_id=$(gh api user --jq '.id')
    note "approving deployment $pending_id"
    gh api "repos/$REPO/actions/runs/$run_id/pending_deployments/$pending_id/approve" \
        --method PUT \
        --input - <<ENDJSON 2>&1 | tee "$LOGS/approve.log" | head -3
{"environment_ids": [], "state": "approved", "comment_ids": [], "reviewers": [{"id": "$user_id"}]}
ENDJSON
    note "[ok] 审批已提交"
}

do_assert_done() {
    step "assert-done" "断言 job succeeded + 状态历史完整"
    local run_id
    run_id=$(gh api "repos/${REPO}/actions/runs?per_page=10" \
        --jq "[.workflow_runs[] | select(.name==\"${WF_NAME}\")][0].id")
    local i=0 conclusion=""
    while [ "$i" -lt 60 ]; do
        conclusion=$(gh api "repos/$REPO/actions/runs/$run_id" \
            --jq '.conclusion' 2>/dev/null || echo "")
        [ "$conclusion" != "null" ] && [ -n "$conclusion" ] && break
        i=$((i+1)); sleep 3
    done
    note "run conclusion: $conclusion"
    [ "$conclusion" = "success" ] \
        || { echo "    [!] 审批后 run 结论=$conclusion，期望 success" >&2; exit 1; }
    # 查 deployment 状态历史
    local deploy_id
    deploy_id=$(gh api "repos/$REPO/deployments?environment=${ENV_NAME}&per_page=1" \
        --jq '.[0].id' 2>/dev/null || echo "")
    if [ -n "$deploy_id" ]; then
        note "deployment $deploy_id 状态历史："
        gh api "repos/$REPO/deployments/$deploy_id/statuses" \
            --jq '.[] | "\(.state)  \(.created_at)"' | sed 's/^/        /' \
            | tee "$LOGS/deployment-history.txt"
    fi
    note "[ok] 审批后 run success"
}

do_clean() {
    step "clean" "删 environment（可选：保留仓库作学习资产）"
    gh api "repos/$REPO/environments/${ENV_NAME}" --method DELETE 2>&1 | head -1 || true
    note "[ok] environment ${ENV_NAME} 已删"
    rm -rf "$LOGS"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        setup)          do_setup ;;
        trigger)        do_trigger ;;
        assert-pending) do_assert_pending ;;
        approve)        do_approve ;;
        assert-done)    do_assert_done ;;
        clean)          do_clean ;;
        all)            do_setup; do_trigger; do_assert_pending; do_approve; do_assert_done; do_clean ;;
        *) echo "可用: setup | trigger | assert-pending | approve | assert-done | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
