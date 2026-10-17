#!/usr/bin/env bash
# =============================================================================
# 07 · OIDC 短时凭据 — 主演示脚本
#
# 完整生命周期：push → wait → download → verify → tamper → clean
# 用法：
#   ./oidc_token.sh push      # 推 workflow 到真仓库（gh api 绕过 git push）
#   ./oidc_token.sh wait      # 等待 run 完成
#   ./oidc_token.sh download  # 下载 artifact 到本地
#   ./oidc_token.sh verify    # JWKS 验签 + claims 断言
#   ./oidc_token.sh tamper    # 篡改 payload → 验签失败（反例取证）
#   ./oidc_token.sh clean     # 清临时文件
#   ./oidc_token.sh           # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

REPO="yong-huang/cicd-lab"
LOGS=".logs"
WF_NAME="oidc-token-demo"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

ensure_ready() {
    command -v gh >/dev/null || { echo "需要 gh CLI" >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "需要 gh auth login" >&2; exit 1; }
    command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }
    python3 -c "from cryptography.hazmat.primitives.asymmetric import padding" 2>/dev/null \
        || { echo "需要 cryptography 库：pip install cryptography" >&2; exit 1; }
    mkdir -p "$LOGS"
}

do_push() {
    step "push" "推 workflow 到真仓库（gh api 绕过 git push）"
    ensure_ready
    local content
    content=$(base64 < workflows/oidc-token-demo.yml)
    gh api "repos/$REPO/contents/.github/workflows/oidc-token-demo.yml" \
        --method PUT \
        --input - <<ENDJSON 2>&1 | python3 -c "import json,sys; print('pushed:', json.load(sys.stdin)['commit']['sha'][:8])" | sed 's/^/        /'
{"message": "feat: OIDC token demo", "content": "$content"}
ENDJSON
    note "[ok] workflow 已推送"
}

do_wait() {
    step "wait" "等待 run 完成"
    local i=0 status="" run_id=""
    while [ "$i" -lt 90 ]; do
        run_id=$(gh api "repos/$REPO/actions/runs?per_page=10" \
            --jq "[.workflow_runs[] | select(.name==\"$WF_NAME\")][0].id" 2>/dev/null || echo "")
        if [ -n "$run_id" ]; then
            status=$(gh api "repos/$REPO/actions/runs/$run_id" --jq '.status' 2>/dev/null || echo "")
            [ "$status" = "completed" ] && break
        fi
        i=$((i+1)); sleep 3
    done
    local conclusion
    conclusion=$(gh api "repos/$REPO/actions/runs/$run_id" --jq '.conclusion')
    note "run_id=$run_id  status=$status  conclusion=$conclusion"
    [ "$conclusion" = "success" ] \
        || { echo "    [!] run 结论=$conclusion" >&2; exit 1; }
    note "[ok] run 成功完成"
}

do_download() {
    step "download" "下载 artifact 到本地"
    local run_id
    run_id=$(gh api "repos/$REPO/actions/runs?per_page=10" \
        --jq "[.workflow_runs[] | select(.name==\"$WF_NAME\")][0].id")
    local art_id
    art_id=$(gh api "repos/$REPO/actions/runs/$run_id/artifacts" \
        --jq '.artifacts[0].id')
    note "artifact_id=$art_id"
    gh api "repos/$REPO/actions/artifacts/$art_id/zip" > "$LOGS/oidc-token.zip"
    cd "$LOGS" && python3 -c "
import zipfile, os
with zipfile.ZipFile('oidc-token.zip', 'r') as z:
    z.extractall('.')
" && cd - >/dev/null
    [ -f "$LOGS/oidc-token.txt" ] \
        || { echo "    [!] artifact 解压后无 oidc-token.txt" >&2; exit 1; }
    note "[ok] token 已下载（$(wc -c < "$LOGS/oidc-token.txt" | tr -d ' ') 字节）"
}

do_verify() {
    step "verify" "JWKS 验签 + claims 断言"
    python3 verify_oidc.py "$LOGS/oidc-token.txt"
}

do_tamper() {
    step "tamper" "篡改 payload → 验签失败（反例取证）"
    python3 verify_oidc.py "$LOGS/oidc-token.txt" --tamper
}

do_clean() {
    step "clean" "清临时文件"
    rm -rf "$LOGS"
    note "[ok] 日志已清"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        push)    do_push ;;
        wait)    do_wait ;;
        download) do_download ;;
        verify)  do_verify ;;
        tamper)  do_tamper ;;
        clean)   do_clean ;;
        all)     do_push; do_wait; do_download; do_verify; do_tamper; do_clean ;;
        *) echo "可用: push | wait | download | verify | tamper | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
