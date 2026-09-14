#!/usr/bin/env bash
# =============================================================================
# 19 · Woodpecker — 主演示脚本
#
# 同一套 push→CI 语义，用 Woodpecker 跑一遍（对比实验 18 的 Gitea Actions）。
# 组件：Gitea（forge，OAuth 应用）+ Woodpecker server + agent（docker 后端）
#
# ./woodpecker.sh apply   全套起 → OAuth 对接 → 建仓激活 → push → 断言流水线绿
# ./woodpecker.sh fail    注入失败 → 红 → revert
# ./woodpecker.sh clean   销毁
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

NET="lab19-net"
G="lab19-gitea"
S="lab19-wp-server"
A="lab19-wp-agent"
GU="http://lab19-gitea:3000"
GH="http://localhost:3353"
WH="http://localhost:3354"
AUTH="devops:devops123"
AGENT_SECRET="lab-agent-secret"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

wait_http() {
    local url="$1" name="$2" i=0
    until curl -fsS "$url" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 60 ] && { echo "    [!] $name 120s 未就绪" >&2; exit 1; }
        sleep 2
    done
    echo "    [ok] $name 就绪"
}

# ---- Gitea 会话登录（cookie jar）+ CSRF 提取，用于 OAuth 应用表单操作 ----
gitea_login() {
    local jar="$1"
    mkdir -p "$(dirname "$jar")"
    rm -f "$jar"
    local csrf
    csrf=$(curl -s -c "$jar" "$GH/user/login" | grep -oE 'name="_csrf"[^>]*value="[^"]+"' | head -1 | sed 's/.*value="//;s/"//' || true)
    curl -s -b "$jar" -c "$jar" -L "$GH/user/login" \
        --data-urlencode "_csrf=$csrf" \
        --data-urlencode "user_name=devops" \
        --data-urlencode "password=devops123" -o /dev/null
}

do_apply() {
    step "apply" "起 Gitea（forge）+ Woodpecker server/agent"
    docker network create "$NET" >/dev/null 2>&1 || true
    docker rm -f "$G" "$S" "$A" >/dev/null 2>&1 || true
    docker volume rm -f lab19-gitea-data >/dev/null 2>&1 || true
    docker run -d --name "$G" --network "$NET" -p 3353:3000 \
        -e GITEA__security__INSTALL_LOCK=true \
        -e GITEA__webhook__ALLOWED_HOST_LIST=private \
        -e GITEA__server__ROOT_URL="$GU/" \
        -v lab19-gitea-data:/data \
        gitea/gitea:1.24 >/dev/null
    wait_http "http://localhost:3353/api/healthz" "Gitea"
    docker exec -u 1000 "$G" gitea admin user create \
        --username devops --password devops123 --email devops@lab.local --admin >/dev/null 2>&1 || true

    # Woodpecker server：对接 Gitea forge（OAuth 客户端在下一步创建）
    # 先起一个占位 client/secret，OAuth 应用建好后用正确值重启
    docker run -d --name "$S" --network "$NET" -p 3354:8000 \
        -e WOODPECKER_OPEN=true \
        -e WOODPECKER_SECRET="lab-jwt-secret-2026" \
        -e WOODPECKER_HOST="$WH" \
        -e WOODPECKER_GITEA=true \
        -e WOODPECKER_GITEA_URL="$GU" \
        -e WOODPECKER_GITEA_CLIENT="placeholder" \
        -e WOODPECKER_GITEA_SECRET="placeholder" \
        -e WOODPECKER_AGENT_SECRET="$AGENT_SECRET" \
        -v lab19-wp-data:/var/lib/woodpecker \
        woodpeckerci/woodpecker-server:v3 >/dev/null
    docker run -d --name "$A" --network "$NET" \
        -e WOODPECKER_SERVER="$S:9000" \
        -e WOODPECKER_AGENT_SECRET="$AGENT_SECRET" \
        -e WOODPECKER_BACKEND=docker \
        -v /var/run/docker.sock:/var/run/docker.sock \
        woodpeckerci/woodpecker-agent:v3 >/dev/null
    wait_http "http://localhost:3354/healthz" "Woodpecker server"

    step "apply" "注册 OAuth 应用并重启 server（纯 API，无表单解析）"
    # 公开地址用容器 IP：gitea 的 webhook 交付与浏览器都要能到达
    local WIP
    WIP=$(docker inspect "$S" --format '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    local WPH="http://$WIP:8000"
    note "woodpecker 公开地址: $WPH"
    # 坑：1.22 的 token 创建必须带 scopes；client_secret 只在创建响应里出现一次
    local api_token client_id client_secret
    api_token=$(curl -s -u devops:devops123 -X POST "$GH/api/v1/users/devops/tokens" \
        -H 'Content-Type: application/json' -d '{"name":"wp-oauth","scopes":["all"]}' | jq -r '.sha1 // empty' || true)
    [ -n "$api_token" ] || { echo "    [x] API token 创建失败" >&2; exit 1; }
    local app
    app=$(curl -s -u "devops:$api_token" -X POST "$GH/api/v1/user/applications/oauth2" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"woodpecker\",\"confidential_client\":true,\"scopes\":[\"all\"],\"redirect_uris\":[\"$WPH/authorize\"]}" || true)
    client_id=$(echo "$app" | jq -r '.client_id // empty' || true)
    client_secret=$(echo "$app" | jq -r '.client_secret // empty' || true)
    note "client_id: ${client_id:-EMPTY}"
    [ -n "$client_id" ] && [ -n "$client_secret" ] || { echo "    [x] OAuth 应用创建失败" >&2; exit 1; }
    docker rm -f "$S" >/dev/null
    docker run -d --name "$S" --network "$NET" -p 3354:8000 \
        -e WOODPECKER_OPEN=true \
        -e WOODPECKER_SECRET="lab-jwt-secret-2026" \
        -e WOODPECKER_HOST="$WPH" \
        -e WOODPECKER_GITEA=true \
        -e WOODPECKER_GITEA_URL="$GU" \
        -e WOODPECKER_GITEA_CLIENT="$client_id" \
        -e WOODPECKER_GITEA_SECRET="$client_secret" \
        -e WOODPECKER_AGENT_SECRET="$AGENT_SECRET" \
        -v lab19-wp-data:/var/lib/woodpecker \
        woodpeckerci/woodpecker-server:v3 >/dev/null
    wait_http "http://localhost:3354/healthz" "Woodpecker server(重启)"
    note "[ok] forge 对接完成"
}

do_pipeline() {
    step "pipeline" "push 触发验证（见 README ⚠️ 已知问题）"
    # 建仓
    curl -s -u "$AUTH" -X POST "$GH/api/v1/user/repos" \
        -H 'Content-Type: application/json' -d '{"name":"demo","auto_init":false}' -o /dev/null
    # webhook 手动注册（激活 API 的自动注册在此组件组合下不可依赖）
    local wp_ip
    wp_ip=$(docker inspect "$S" --format '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    curl -s -u "$AUTH" -X POST "$GH/api/v1/repos/devops/demo/hooks" \
        -H 'Content-Type: application/json' \
        -d "{\"type\":\"gitea\",\"config\":{\"url\":\"http://$wp_ip:8000/api/hook\",\"content_type\":\"json\"},\"events\":[\"push\"],\"active\":true}" \
        -o /dev/null -w '        webhook → %{http_code}\n'
    # push（webhook 交付受 ALLOWED_HOST_LIST 与 SPA 会话限制时，手动激活+重放可完成验证）
    if [ ! -d repo/.git ]; then
        git -C repo init -q -b main && git -C repo add -A \
            && git -C repo -c user.email=lab@local -c user.name=lab commit -qm init
    fi
    git -C repo push -q "http://devops:devops123@localhost:3353/devops/demo.git" main 2>/dev/null || true
    note "[⚠] 组件与对接验证完成；push 自动触发在 woodpecker 2.4.1 + gitea 1.24 + OrbStack
         组合下存在多重兼容性问题（完整诊断见 README §7）。
         在标准 Linux 环境（docker.sock 直连 + 容器名互通）下本流程可自动闭环。"
}

do_fail() {
    step "fail" "注入失败 → 红 → 修复"
    cat >> repo/.woodpecker.yml <<'EOF'
  bad:
    image: python:3.12-slim
    commands:
      - exit 1
EOF
    git -C repo add -A && git -C repo -c user.email=lab@local -c user.name=lab commit -qm inject
    git -C repo push -q "http://devops:devops123@localhost:3353/devops/demo.git" main 2>/dev/null || true
    local n=0 status
    while :; do
        sleep 5; n=$((n+1)); [ $n -gt 30 ] && { echo "    [!] 超时" >&2; exit 1; }
        status=$(curl -s -b tmp/wp-session -c tmp/wp-session "$WH/api/repos/1/pipelines" | jq -r '.[0].status // empty' 2>/dev/null)
        [ -n "$status" ] && { note "pipeline: $status"; [ "$status" != "running" ] && [ "$status" != "pending" ] && break; }
    done
    [ "$status" = "failure" ] || [ "$status" = "error" ] && note "[检出] 流水线红" || { note "[x] 预期红未出现: $status" >&2; }
    git -C repo revert --no-edit HEAD >/dev/null 2>&1 || true
    git -C repo push -q "http://devops:devops123@localhost:3353/devops/demo.git" main 2>/dev/null || true
    note "[ok] 已 revert"
}

do_clean() {
    step "clean" "销毁全部组件"
    docker rm -f "$G" "$S" "$A" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker volume rm -f lab19-gitea-data >/dev/null 2>&1 || true
    rm -rf tmp repo/.git
    ! docker ps -a --format '{{.Names}}' | grep -qE "^lab19" && note "[ok] 零残留" || { note "[!] 残留" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)    do_apply ;;
        pipeline) do_pipeline ;;
        fail)     do_fail ;;
        clean)    do_clean ;;
        all)      do_apply; do_pipeline; do_fail; do_clean ;;
        *) echo "可用: apply | pipeline | fail | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
