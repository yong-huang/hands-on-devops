#!/usr/bin/env bash
# =============================================================================
# 20 · 完整 CI/CD — 主演示脚本
#
# 复用实验 18 的 Gitea Actions（已验证），注入完整门禁与追溯：
# push → 测试 → 构建 → SBOM 归档 → 部署 → 冒烟，每次发布留痕
#
# ./cicd_full.sh apply    全套起 → 建仓 → push → 断言全绿 + 追溯清单
# ./cicd_full.sh fail     注入失败用例 → 断言全链路阻断
# ./cicd_full.sh clean    销毁
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

NET="lab20-net"
G="lab20-gitea"
R="lab20-runner"
GH="http://lab20-gitea:3000"
GU="http://localhost:3355"
AUTH="devops:devops123"

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

# act_runner 的 job 结果不打印到自己的 stdout（只流回 Gitea）——
# 在 runner 日志里 grep ✅ 永远等不到。权威状态源：Gitea DB（镜像自带 sqlite3）。
# status 字典：1=Success 2=Failure 3=Cancelled 4=Skipped 5=Waiting 6=Running 7=Blocked
last_run_status() {
    docker exec "$G" sqlite3 /data/gitea/gitea.db \
        "SELECT status FROM action_run ORDER BY id DESC LIMIT 1" 2>/dev/null || echo ""
}
status_name() {
    case "$1" in 1) echo Success;; 2) echo Failure;; 3) echo Cancelled;; 4) echo Skipped;; 5) echo Waiting;; 6) echo Running;; 7) echo Blocked;; *) echo "unknown($1)";; esac
}

do_apply() {
    step "apply" "起 Gitea（Actions）+ act_runner"
    docker network create "$NET" >/dev/null 2>&1 || true
    docker rm -f "$G" "$R" >/dev/null 2>&1 || true
    docker volume rm -f lab20-gitea-data >/dev/null 2>&1 || true
    docker run -d --name "$G" --network "$NET" -p 3355:3000 \
        -e GITEA__security__INSTALL_LOCK=true \
        -e GITEA__actions__ENABLED=true \
        -e GITEA__server__ROOT_URL="$GU/" \
        -v lab20-gitea-data:/data \
        gitea/gitea:1.22 >/dev/null
    wait_http "$GU/api/healthz" "Gitea"
    docker exec -u 1000 "$G" gitea admin user create \
        --username devops --password devops123 --email devops@lab.local --admin >/dev/null 2>&1 || true

    local token
    token=$(docker exec -u 1000 "$G" gitea actions generate-runner-token 2>/dev/null)
    local socket_path="${DOCKER_HOST#unix://}"
    docker run -d --name "$R" --network "$NET" \
        -e GITEA_INSTANCE_URL="$GH" \
        -e GITEA_RUNNER_REGISTRATION_TOKEN="$token" \
        -e GITEA_RUNNER_NAME="lab-runner" \
        -e GITEA_RUNNER_LABELS="lab:docker://python:3.12-slim" \
        -v "$socket_path:/var/run/docker.sock" \
        gitea/act_runner:latest >/dev/null
    note "[ok] runner 注册完成"

    step "apply" "建仓 + push（触发完整流水线）"
    curl -s -u "$AUTH" -X POST "$GU/api/v1/user/repos" \
        -H 'Content-Type: application/json' -d '{"name":"demo","auto_init":false}' -o /dev/null
    if [ ! -d repo/.git ]; then
        git -C repo init -q -b main && git -C repo add -A \
            && git -C repo -c user.email=lab@local -c user.name=lab commit -qm init
    fi
    git -C repo push -q "http://devops:devops123@localhost:3355/devops/demo.git" main 2>/dev/null || true

    step "apply" "等待流水线（状态源：Gitea DB）"
    local n=0 st=""
    while :; do
        sleep 3; n=$((n+1)); [ $n -gt 40 ] && { note "[!] 超时——看 $GU/devops/demo/actions" >&2; exit 1; }
        st=$(last_run_status)
        case "$st" in
            1) break ;;
            2) echo "        ❌ 流水线 Failure——看 $GU/devops/demo/actions" >&2; exit 1 ;;
            5|6|"") echo "        …$(status_name "${st:-6}")" ;;
            *) echo "        ❌ 流水线异常状态：$(status_name "$st")" >&2; exit 1 ;;
        esac
    done
    note "[ok] 流水线全绿（Gitea status=Success）"
}

do_fail() {
    step "fail" "注入失败用例 → 断言阻断"
    cat >> repo/.gitea/workflows/release.yml <<'EOF'
      - name: injected
        run: exit 1
EOF
    git -C repo add -A && git -C repo -c user.email=lab@local -c user.name=lab commit -qm inject
    git -C repo push -q "http://devops:devops123@localhost:3355/devops/demo.git" main 2>/dev/null || true
    local n=0 st=""
    while :; do
        sleep 3; n=$((n+1)); [ $n -gt 20 ] && break
        st=$(last_run_status)
        { [ "$st" = "2" ] || [ "$st" = "1" ]; } && break
    done
    [ "$st" = "2" ] && note "[检出] 注入被抓住（run status=Failure，流水线阻断）" \
        || { echo "        ❌ 注入未被标记 Failure（status=$(status_name "$st")）" >&2; exit 1; }
    git -C repo revert --no-edit HEAD >/dev/null 2>&1 || true
    git -C repo push -q "http://devops:devops123@localhost:3355/devops/demo.git" main 2>/dev/null || true
    note "[ok] 已 revert"
}

do_clean() {
    step "clean" "销毁"
    docker rm -f "$G" "$R" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker volume rm -f lab20-gitea-data >/dev/null 2>&1 || true
    rm -rf repo/.git
    ! docker ps -a --format '{{.Names}}' | grep -qE "^lab20" && note "[ok] 零残留" || { note "[!] 残留" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply) do_apply ;;
        fail)  do_fail ;;
        clean) do_clean ;;
        all)   do_apply; do_fail; do_clean ;;
        *) echo "可用: apply | fail | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
