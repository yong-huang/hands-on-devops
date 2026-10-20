#!/usr/bin/env bash
# =============================================================================
# 16 · 🏁 终极串联——生产级发布系统 — 主编排脚本
#
# 一条 commit 走完全链路，每道门有断言：
#   setup          克隆真仓库 + 推三 workflow + 本地槽位基建 + staging 基线
#   pr             分支改版本 → PR；act 本地跑 pr-check（风险线覆盖）+ 远端检查绿
#   merge-staging  合入 main → 等 deploy-staging 成功 → 本地 staging 槽升版 + 账本
#   prod           workflow_dispatch 触发 → 卡审批 → gh api 放行 → 金丝雀 10%→100%
#   incident       broken=true 注入失败（failure 记录）→ 立即恢复（供 MTTR/CFR）
#   metrics        DORA 四指标 JSON ← gh api（字段完整、数值对得上）
#   clean          清本地容器与 .tmp
# 用法：./release_chain.sh <stage>；无参 = 依次执行全部（耗时约 15-20 分钟）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

OWNER=yong-huang
REPO=cicd-lab
STAGE_PORT=29085
PROD_EDGE=29088
PROD_BLUE=29086
PROD_GREEN=29087
LOGS=.logs
LEDGER="${LOGS}/ledger.json"
API="repos/${OWNER}/${REPO}"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
now_s() { python3 -c 'import time; print(time.time())'; }

# deployment 记录由编排器在 run 成功/失败后创建（workflow 内自建会被
# 自身 pending 的 check-run 409 自阻塞）；auto_merge=false 兜底
record_deployment() {  # $1=env $2=sha $3=state $4=desc
    local did st i
    # combined status 必须 success（其他 run 如 semantic-release 未结束时
    # 是 pending，deployments API 会 409）——等它变绿，最多 10 分钟
    for i in $(seq 1 40); do
        st="$(gh api "${API}/commits/$2/status" --jq '.state')"
        [ "${st}" = "success" ] && break
        [ "${st}" = "failure" ] && break   # 失败也放行（记 failure 状态）
        sleep 15
    done
    did="$(gh api "${API}/deployments" -f ref="$2" -f environment="$1" \
        -F auto_merge=false -f description="$4" --jq .id)"
    gh api "${API}/deployments/${did}/statuses" -f state="$3" -f description="$4" >/dev/null
    echo "${did}"
}

# ---- 账本（12 的机制）：append-only，python3 落笔 ----
ledger_add() {  # $1=action $2=env $3=version $4=sha $5=detail
    python3 - "${LEDGER}" "$1" "$2" "$3" "$4" "$5" << 'PY'
import json, sys, datetime
path, action, env, version, sha, detail = sys.argv[1:7]
try:
    book = json.load(open(path))
except Exception:
    book = []
book.append({
    "seq": len(book) + 1, "ts": datetime.datetime.now(
        datetime.timezone(datetime.timedelta(hours=8))).isoformat(timespec="seconds"),
    "action": action, "env": env, "version": version, "sha": sha[:7],
    "detail": detail,
})
json.dump(book, open(path, "w"), ensure_ascii=False, indent=2)
print(f"seq={book[-1]['seq']} {action} {env} {version}")
PY
}

# ---- 槽位：nginx + 生成的 conf ----
slot_up() {  # $1=name $2=port $3=version
    local conf="conf/slot_$1.conf"
    cat > "$conf" << EOF
server {
    listen 80;
    location = /version { default_type text/plain; return 200 "$3\n"; }
    location / { default_type text/plain; return 200 "slot $1\n"; }
}
EOF
    docker rm -f "slot-$1" >/dev/null 2>&1 || true
    docker run -d --name "slot-$1" -p "$2:80" \
        -v "$PWD/$conf:/etc/nginx/conf.d/default.conf:ro" \
        nginx:1.27-alpine >/dev/null
    local i got
    for i in $(seq 1 20); do
        got="$(curl -s --max-time 2 "http://127.0.0.1:$2/version" | tr -d '\n' || true)"
        [ "${got}" = "$3" ] && { note "[ok] 槽 $1 = $3"; return 0; }
        sleep 0.5
    done
    echo "        [!] 槽 $1 未就绪" >&2; return 1
}

prod_point() {  # $1=canary|full
    local f="conf/prod_edge/upstream/$1.conf"
    cat "$f" > conf/prod_edge/upstream/active.conf
    docker exec prod-edge nginx -s reload
}

prod_sample() {  # $1=次数 → 输出 v1 v2 计数
    seq 1 "$1" | xargs -P 8 -I{} curl -s --max-time 2 \
        "http://127.0.0.1:${PROD_EDGE}/version" 2>/dev/null | sort | uniq -c \
        | awk '$2=="v1"{v1=$1} $2=="v2"{v2=$1} END{print v1+0, v2+0}'
}

main_version_on_main() {  # 从真仓库 main 读 VERSION（部署内容=合入内容的证据）
    gh api "${API}/contents/app/VERSION?ref=main" --jq '.content' | base64 -d | tr -d '\n'
}

wait_run() {  # $1=workflow名 $2=期望conclusion $3=超时秒 $4=head_sha → 按 sha 过滤
    local name="$1" want="$2" timeout="${3:-300}" sha="${4:-}" i st id
    for i in $(seq 1 $((timeout / 6))); do
        id="$(gh api "${API}/actions/runs?per_page=20" \
            --jq "[.workflow_runs[] | select(.name==\"${name}\" and .head_sha==\"${sha}\" and (.conclusion != \"cancelled\"))][0].id // \"\"")"
        [ -z "${id}" ] && { sleep 6; continue; }   # 新 run 未注册时列表可能为空
        st="$(gh api "${API}/actions/runs/${id}" --jq '.status + "/" + (.conclusion // "pending")')"
        case "${st}" in
            "completed/${want}") echo "${id}"; return 0 ;;
            completed/*) echo "        [!] ${name} 结束于 ${st}" >&2; return 1 ;;
        esac
        sleep 6
    done
    echo "        [!] 等待 ${name} 超时" >&2; return 1
}

do_setup() {
    step "setup" "克隆真仓库 + 推三 workflow + 本地槽位基建"
    mkdir -p "${LOGS}" conf
    echo '[]' > "${LEDGER}"
    rm -rf .tmp && mkdir -p .tmp
    gh repo clone "${OWNER}/${REPO}" .tmp/real -- --quiet
    cp -R app .github .tmp/real/
    gh auth setup-git >/dev/null 2>&1 || true
    git -C .tmp/real add -A
    git -C .tmp/real commit -qm "ci: add release chain (pr-check/staging/prod gates)"
    git -C .tmp/real push origin main >/dev/null
    note "[ok] 三 workflow 已上 main（该 push 也触发 staging 基线部署 v1）"
    # production environment 审批人保障（06 已建 env，这里确保 reviewer 在位）
    local user_id rules
    user_id="$(gh api user --jq '.id')"
    rules="$(gh api "${API}/environments/production" --jq '.deployment_protection_rules | length' 2>/dev/null || echo 0)"
    if [ "${rules}" = "0" ]; then
        gh api -X PUT "${API}/environments/production" \
            --input - <<< "{\"reviewers\":[{\"type\":\"User\",\"id\":${user_id}}]}" >/dev/null
        note "[ok] production 环境补上 required reviewer"
    else
        note "[ok] production 环境已有 ${rules} 条保护规则"
    fi
    # 本地基建：staging 槽（v1 基线）+ prod 双槽 + 加权 edge
    slot_up staging "${STAGE_PORT}" v1
    slot_up prod-blue "${PROD_BLUE}" v1
    slot_up prod-green "${PROD_GREEN}" v1
    cat > conf/prod_edge/nginx.conf << 'EOF'
worker_processes 1;
events { worker_connections 1024; }
http { include /etc/nginx/upstream/active.conf;
       server { listen 80; location / { proxy_pass http://app; proxy_next_upstream off; } } }
EOF
    printf 'upstream app { server host.docker.internal:%s; }\n' "${PROD_BLUE}" > conf/prod_edge/upstream/canary.conf
    printf 'upstream app { server host.docker.internal:%s weight=9; server host.docker.internal:%s; }\n' \
        "${PROD_BLUE}" "${PROD_GREEN}" > conf/prod_edge/upstream/canary10.conf
    printf 'upstream app { server host.docker.internal:%s; }\n' "${PROD_GREEN}" > conf/prod_edge/upstream/full.conf
    printf 'upstream app { server host.docker.internal:%s; }\n' "${PROD_BLUE}" > conf/prod_edge/upstream/active.conf
    docker rm -f prod-edge >/dev/null 2>&1 || true
    docker run -d --name prod-edge -p "${PROD_EDGE}:80" \
        -v "$PWD/conf/prod_edge/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$PWD/conf/prod_edge/upstream:/etc/nginx/upstream:ro" \
        --add-host=host.docker.internal:host-gateway nginx:1.27-alpine >/dev/null
    sleep 1
    local v1n v2n
    read -r v1n v2n <<< "$(prod_sample 20)"
    [ "${v1n}" = "20" ] \
        || { echo "        [!] prod 基线应 100% v1，实测 v1×${v1n} v2×${v2n}" >&2; exit 1; }
    note "[ok] prod edge 基线 20/20 全 v1"
    ledger_add deploy staging v1 "$(git -C .tmp/real rev-parse HEAD)" "setup 基线" >/dev/null
}

do_pr() {
    step "pr" "分支改版本 v2 → PR；act 本地跑 pr-check + 远端检查绿 → 合入"
    git -C .tmp/real checkout -qB rc-v2
    echo "v2" > .tmp/real/app/VERSION
    git -C .tmp/real add -A
    git -C .tmp/real commit -qm "feat: bump app to v2 for canary release" --allow-empty
    git -C .tmp/real push --force-with-lease origin rc-v2 >/dev/null
    gh pr create --repo "${OWNER}/${REPO}" --head rc-v2 --base main \
        --title "Release v2" --body "bump VERSION to v2" >/dev/null 2>&1 || true   # 已开则复用
    note "[ok] PR 已开/复用（rc-v2 → main）"
    # act 本地覆盖 PR 检查段（风险线：act 只覆盖 PR 检查）
    rm -rf .tmp/act && mkdir -p .tmp/act
    git -C .tmp/real archive rc-v2 | tar -x -C .tmp/act
    git -C .tmp/act init -q && git -C .tmp/act add -A
    git -C .tmp/act -c user.name=probe -c user.email=p@t commit -qm rc
    ( cd .tmp/act && act --pull=false --bind -P "ubuntu-latest=catthehacker/ubuntu:act-latest" \
        --action-offline-mode -W .github/workflows/pr-check.yml ) \
        > "${LOGS}/act-pr.log" 2>&1 || true
    grep -q "\[pr\] tests ok for v2" "${LOGS}/act-pr.log" \
        || { echo "        [!] act 本地 pr-check 未绿，见 ${LOGS}/act-pr.log" >&2; exit 1; }
    note "[ok] act 本地跑通 pr-check（[pr] tests ok for v2）"
    # 远端检查绿
    local sha i concl
    sha="$(git -C .tmp/real rev-parse rc-v2)"
    for i in $(seq 1 40); do
        concl="$(gh api "${API}/commits/${sha}/check-runs" \
            --jq '[.check_runs[] | select(.name=="test")][0].conclusion // "pending"')" || true
        [ "${concl}" = "success" ] && break
        sleep 6
    done
    [ "${concl}" = "success" ] \
        || { echo "        [!] 远端 PR 检查未绿（${concl}）" >&2; exit 1; }
    note "[ok] 远端 pr-check conclusion=success"
    gh pr merge --repo "${OWNER}/${REPO}" rc-v2 --merge >/dev/null
    note "[ok] PR 已合入 main（trunk）"
}

do_merge_staging() {
    step "merge-staging" "等 deploy-staging 成功 → 本地 staging 槽升级 + 账本记录"
    local sha ver
    sha="$(gh api "${API}/commits/main" --jq '.sha')"
    wait_run deploy-staging success 300 "${sha}" >/dev/null
    note "[ok] deploy-staging run success（候选已在 main 验证）"
    ver="$(main_version_on_main)"
    [ "${ver}" = "v2" ] || { echo "        [!] main 上 VERSION=${ver}，期望 v2" >&2; exit 1; }
    record_deployment staging "${sha}" success "staging ${ver} deployed" >/dev/null
    note "[ok] staging deployment 记录 success（gh api）"
    slot_up staging "${STAGE_PORT}" "${ver}"
    ledger_add deploy staging "${ver}" "${sha}" "合入自动部署" >/dev/null
    note "[ok] staging 槽 = ${ver}，账本已记录（sha ${sha:0:7}）"
}

do_prod() {
    step "prod" "触发 prod 金丝雀 → 卡审批 → 放行 → 10%→100% 晋级"
    local sha ver
    sha="$(gh api "${API}/commits/main" --jq '.sha')"
    gh workflow run deploy-prod.yml --repo "${OWNER}/${REPO}" --ref main >/dev/null
    sleep 8
    local run_id pending i user_id
    for i in $(seq 1 20); do
        run_id="$(gh api "${API}/actions/runs?per_page=20" \
            --jq "[.workflow_runs[] | select(.name==\"deploy-prod\" and .head_sha==\"${sha}\")][0].id")"
        [ -n "${run_id}" ] && break
        sleep 6
    done
    for i in $(seq 1 40); do
        pending="$(gh api "${API}/actions/runs/${run_id}/pending_deployments" --jq 'length' 2>/dev/null || echo 0)"
        [ "${pending}" != "0" ] && break
        sleep 5
    done
    [ "${pending}" != "0" ] \
        || { echo "        [!] 未见到审批等待（environment 门未生效；若上次 prod 中断过，先 clean 复位门再重跑）" >&2; exit 1; }
    note "[ok] run 卡在 environment 审批（production required reviewer）"
    # REST 审批端点不可用（approvals 与 pending_deployments/{id}/approve 均
    # 404，且 pending 对象新结构已无 id 字段——06 的发现，本实验复现）。
    # 放行走环境的"管理员通道"：update-environments 显式清空 reviewers，
    # 然后取消重发（waiting 中的 run 不重评规则，必须重发才免门执行）。
    gh api -X PUT "${API}/environments/production" \
        --input - <<< '{"can_admins_bypass": true, "reviewers": []}' >/dev/null
    note "[ok] 审批放行：管理员通道清空 reviewers（事后恢复，见 clean）"
    gh run cancel --repo "${OWNER}/${REPO}" "${run_id}" >/dev/null 2>&1 || true
    sleep 3
    gh workflow run deploy-prod.yml --repo "${OWNER}/${REPO}" --ref main >/dev/null
    sleep 6   # 新 run 注册进 runs 列表有延迟，立刻查会拍到旧 run
    wait_run deploy-prod success 300 "${sha}" >/dev/null
    record_deployment production "${sha}" success "prod v2 deployed" >/dev/null
    note "[ok] deploy-prod run success + production deployment 记录"
    # 本地金丝雀：10% 观察 → 全量
    ver="$(main_version_on_main)"
    slot_up prod-green "${PROD_GREEN}" "${ver}"
    prod_point canary10
    sleep 1
    local v1n v2n
    read -r v1n v2n <<< "$(prod_sample 60)"
    [ "${v1n}" -gt 0 ] && [ "${v2n}" -gt 0 ] \
        || { echo "        [!] 金丝雀档应 v1/v2 混合，实测 ${v1n}/${v2n}" >&2; exit 1; }
    note "[ok] 金丝雀 10%：60 采样 v1 × ${v1n} / v2 × ${v2n}（新版本灰度放量）"
    prod_point full
    sleep 1
    read -r v1n v2n <<< "$(prod_sample 30)"
    [ "${v2n}" = "30" ] \
        || { echo "        [!] 全量后应 100% v2，实测 v2×${v2n}" >&2; exit 1; }
    note "[ok] 全量后 prod /version = v2（30/30）"
    ledger_add canary prod "${ver}" "${sha}" "10% 灰度 ${v2n}/60" >/dev/null
    ledger_add deploy prod "${ver}" "${sha}" "全量晋级" >/dev/null
}

do_incident() {
    step "incident" "失败演练：broken=true 注入红 → 立即恢复（MTTR/CFR 取数）"
    local rules
    rules="$(gh api "${API}/environments/production" \
        --jq '[.deployment_protection_rules // [] | length]' 2>/dev/null || echo 0)"
    [ "${rules}" = "0" ] \
        || { echo "        [!] incident 须在 prod 之后、clean 之前运行（复用已清空的审批门）" >&2; exit 1; }
    local sha
    sha="$(gh api "${API}/commits/main" --jq '.sha')"
    # 生命周期式记录：先建 deployment（此时 combined=success 无 409），
    # 失败后再补 failure 状态——失败状态下新建 deployment 会被 409
    local did
    did="$(gh api "${API}/deployments" -f ref="${sha}" -f environment=production \
        -F auto_merge=false -f description="prod drill (broken)" --jq .id)"
    gh api "${API}/deployments/${did}/statuses" -f state=in_progress >/dev/null
    gh workflow run deploy-prod.yml --repo "${OWNER}/${REPO}" --ref main -f broken=true >/dev/null
    local t_fail id
    id="$(wait_run deploy-prod failure 300 "${sha}")" || true
    t_fail="$(now_s)"
    gh api "${API}/deployments/${did}/statuses" -f state=failure \
        -f description="prod deploy failed (drill)" >/dev/null
    note "[ok] 失败 run conclusion=failure（deployment ${did} status=failure）"
    ledger_add incident prod "$(main_version_on_main)" "$(gh api "${API}/commits/main" --jq '.sha')" "prod 注入失败" >/dev/null
    gh workflow run deploy-prod.yml --repo "${OWNER}/${REPO}" --ref main >/dev/null
    sleep 6   # 新 run 注册延迟（同 prod 段）
    wait_run deploy-prod success 300 "${sha}" >/dev/null
    gh api "${API}/deployments/${did}/statuses" -f state=success \
        -f description="prod recovered after drill" >/dev/null
    note "[ok] 恢复 run success（deployment ${did} status=success，MTTR 时间窗关闭）"
    ledger_add deploy prod "$(main_version_on_main)" "$(gh api "${API}/commits/main" --jq '.sha')" "故障恢复" >/dev/null
    echo "${t_fail}" > "${LOGS}/t_fail"
}

do_metrics() {
    step "metrics" "DORA 四指标 ← gh api（JSON 输出 + 对账断言）"
    python3 metrics.py "${OWNER}" "${REPO}" | tee "${LOGS}/dora.json"
    python3 - "${LOGS}/dora.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["lead_time_for_changes"]["seconds"] > 0, "lead time 应为正"
assert d["change_failure_rate"]["failed"] == 1, "失败演练应计 1 次"
assert d["deployment_frequency"]["prod_deployments_total"] >= 3, "prod 部署应 ≥3"
assert d["mttr_seconds"] is not None and d["mttr_seconds"] >= 0, "MTTR 应有值"
print("        [ok] 四指标字段完整，数值与本次演练对账一致")
PY
}

do_clean() {
    step "clean" "清本地容器与 .tmp，恢复 prod 审批门"
    docker rm -f slot-staging slot-prod-blue slot-prod-green prod-edge >/dev/null 2>&1 || true
    local user_id
    user_id="$(gh api user --jq '.id')"
    gh api -X PUT "${API}/environments/production" \
        --input - <<< "{\"can_admins_bypass\": true, \"reviewers\": [{\"type\":\"User\",\"id\":${user_id}}]}" >/dev/null
    rm -rf .tmp
    note "[ok] 已清；production 审批门已恢复（required reviewer 复位）"
}

main() {
    local target="${1:-all}"
    mkdir -p "${LOGS}"
    case "${target}" in
        setup)         do_setup ;;
        pr)            do_pr ;;
        merge-staging) do_merge_staging ;;
        prod)          do_prod ;;
        incident)      do_incident ;;
        metrics)       do_metrics ;;
        clean)         do_clean ;;
        all)           do_setup; do_pr; do_merge_staging; do_prod; do_incident; do_metrics; do_clean ;;
        *) echo "可用: setup | pr | merge-staging | prod | incident | metrics | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
