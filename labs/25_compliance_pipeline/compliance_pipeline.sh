#!/usr/bin/env bash
# =============================================================================
# 25 · 集成点③：合规流水线 — 主演示脚本
#
# 三道门真实接进 Gitea Actions（复用 20 的基建 + 22/23 的门禁资产）：
#   gate1 策略门 conftest  —— manifests/ 全部过 OPA 规则（22 的策略）
#   gate2 安全门 trivy     —— iac/ 全部过 HIGH+ 阈值（23 的规则库）
#   gate3 密钥门 gitleaks  —— 全仓库无明文凭证（23 的自定义规则）
# 四类 push 实证：合规全绿 / 策略违规红 / 安全违规红 / 凭证泄漏红，
# 权威状态源 = Gitea DB（20 的修复模式）。
#
# ./compliance_pipeline.sh up      Gitea+runner+CI 工具镜像（conftest/trivy/gitleaks）
# ./compliance_pipeline.sh green   push 合规全套 → run Success
# ./compliance_pipeline.sh red     三类违规各 push → run Failure×3
# ./compliance_pipeline.sh clean   销毁
# ./compliance_pipeline.sh all     up → green → red → clean（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

NET="lab25-net"
G="lab25-gitea"
R="lab25-runner"
JOBIMG="lab25-citools:latest"
# GITEA_INSTANCE_URL 必须用「宿主可路由地址」而非容器名：
# act_runner 创建的 job 容器默认 host 网络——解析不了 lab25-net 里的容器名
# （实测 checkout 的 git fetch origin 三次重试失败）。网关 IP 双侧可达。
GW_IP=$(docker network inspect "$NET" 2>/dev/null | python3 -c "
import sys, json
c = json.load(sys.stdin)[0]['IPAM']['Config']
print([x['Gateway'] for x in c if ':' not in x['Gateway']][0])" 2>/dev/null || echo "192.168.147.1")
GH="http://${GW_IP}:3356"
GU="http://localhost:3356"
AUTH="devops:devops123"
REPO="repo"
POLL=150

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

wait_http() {
    local url="$1" name="$2" i=0
    until curl -fsS "$url" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 60 ] && fail "$name 120s 未就绪"
        sleep 2
    done
    note "[ok] $name 就绪"
}

last_run_status() {  # 权威状态源：Gitea DB（status: 1=Success 2=Failure 5=Waiting 6=Running）
    docker exec "$G" sqlite3 /data/gitea/gitea.db \
        "SELECT status FROM action_run ORDER BY id DESC LIMIT 1" 2>/dev/null || echo ""
}
status_name() {
    case "$1" in 1) echo Success;; 2) echo Failure;; 3) echo Cancelled;; 4) echo Skipped;; 5) echo Waiting;; 6) echo Running;; 7) echo Blocked;; *) echo "unknown($1)";; esac
}

wait_run() {  # wait_run <期望状态号>
    local want="$1" n=0 st=""
    while :; do
        sleep 3; n=$((n+1)); [ $n -gt $((POLL / 3)) ] && fail "run 状态等待超时（最后 $(status_name "$st")）"
        st=$(last_run_status)
        { [ "$st" = "$want" ] || [ "$st" = "2" ] || [ "$st" = "1" ]; } && { echo "$st"; return 0; }
        echo "        …$(status_name "${st:-5}")" >&2
    done
}

extract() {  # extract <镜像> <容器内路径> <输出名>：从工具镜像抽二进制
    local cid
    cid=$(docker create "$1") || fail "无法创建容器：$1"
    docker cp "$cid":"$2" "./citools/$3" || fail "二进制抽取失败：$1:$2"
    docker rm -f "$cid" >/dev/null
}

do_up() {
    step up "拉官方工具镜像 → docker cp 抽二进制 → 构建 job 工具镜像"
    # 路线（本网络实测）：github release 大文件被截断/限速，但 docker.io 官方
    # 工具镜像经 daemon 镜像源可拉（小中镜像无碍）——docker cp 抽单二进制
    for spec in "aquasec/trivy:0.74.0" "zricethezav/gitleaks:v8.30.1" "openpolicyagent/conftest:v0.62.0"; do
        docker image inspect "$spec" >/dev/null 2>&1 && continue
        docker pull -q "$spec" >/dev/null 2>&1 || fail "工具镜像拉取失败：$spec"
    done
    extract "aquasec/trivy:0.74.0"                /usr/local/bin/trivy    trivy
    extract "zricethezav/gitleaks:v8.30.1"        /usr/bin/gitleaks       gitleaks
    extract "openpolicyagent/conftest:v0.62.0"    /conftest               conftest
    ok "三件套二进制抽取完成（arm64 ELF）"
    DOCKER_BUILDKIT=0 docker build -q -t "$JOBIMG" citools >/dev/null || fail "工具镜像构建失败"
    docker run --rm "$JOBIMG" sh -c 'conftest --version | head -1; trivy --version | head -1; gitleaks version | head -1' \
        | sed 's/^/        /'
    ok "$JOBIMG 就绪（三件套自检通过）"

    step up "起 Gitea（Actions）+ act_runner（lab 标签 → 工具镜像）"
    docker network create "$NET" >/dev/null 2>&1 || true
    docker rm -f "$G" "$R" >/dev/null 2>&1 || true
    docker volume rm -f lab25-gitea-data >/dev/null 2>&1 || true
    docker run -d --name "$G" --network "$NET" -p 3356:3000 \
        -e GITEA__security__INSTALL_LOCK=true \
        -e GITEA__actions__ENABLED=true \
        -e GITEA__server__ROOT_URL="$GU/" \
        -v lab25-gitea-data:/data \
        gitea/gitea:1.22 >/dev/null
    wait_http "$GU/api/healthz" "Gitea"
    docker exec -u 1000 "$G" gitea admin user create \
        --username devops --password devops123 --email devops@lab.local --admin >/dev/null 2>&1 || true

    local token socket_path
    token=$(docker exec -u 1000 "$G" gitea actions generate-runner-token 2>/dev/null)
    socket_path="${DOCKER_HOST#unix://}"
    docker run -d --name "$R" --network "$NET" \
        -e GITEA_INSTANCE_URL="$GH" \
        -e GITEA_RUNNER_REGISTRATION_TOKEN="$token" \
        -e GITEA_RUNNER_NAME="lab25-runner" \
        -e GITEA_RUNNER_LABELS="lab:docker://$JOBIMG" \
        -v "$socket_path:/var/run/docker.sock" \
        gitea/act_runner:latest >/dev/null
    sleep 5
    docker logs "$R" 2>&1 | grep -aq "registered successfully" \
        && ok "runner 注册完成（labels: lab → ${JOBIMG}）" \
        || fail "runner 注册失败"
}

seed_and_push() {  # seed_and_push <文件...>：仓库只含指定文件（决定哪道门红）
    local -a files=("$@")
    rm -rf "$REPO"
    mkdir -p "$REPO"
    cp -R repo-seed/.gitea "$REPO/"
    cp repo-seed/.gitleaks.toml "$REPO/"
    cp -R policies "$REPO/policies"
    mkdir -p "$REPO/manifests" "$REPO/iac"
    local f
    for f in "${files[@]}"; do
        cp "repo-seed/$f" "$REPO/$f"
    done
    ( cd "$REPO" \
        && git init -q -b main \
        && git add -A \
        && git -c user.email=lab@local -c user.name=lab commit -qm "push: ${files[*]}" \
        && git push -qf "http://${AUTH}@localhost:3356/devops/compliance.git" main )
    note "push 完成（${files[*]}）"
}

do_green() {
    step green "push 合规全套（manifests/iac 均合规）→ 期望 run Success"
    curl -s -u "$AUTH" -X POST "$GU/api/v1/user/repos" \
        -H 'Content-Type: application/json' -d '{"name":"compliance","auto_init":false}' -o /dev/null
    seed_and_push manifests/deployment.yaml iac/main.tf
    local st
    st=$(wait_run 1)
    [ "$st" = "1" ] || fail "合规 push 应 Success，实为 $(status_name "$st")"
    ok "三门全过（run status=Success）——合规变更畅通"
}

do_red() {
    step red "三类违规各 push → 期望 run Failure（哪类违规哪道门拦）"
    note "[场景 1] 策略违规（:latest 镜像）→ gate1 conftest 应拦"
    seed_and_push manifests/deployment.yaml manifests/deployment-latest.yaml iac/main.tf
    st=$(wait_run 2)
    [ "$st" = "2" ] || fail "策略违规应 Failure，实为 $(status_name "$st")"
    ok "gate1 拦下（run status=Failure）"

    note "[场景 2] 安全违规（全开安全组）→ gate2 trivy 应拦"
    seed_and_push manifests/deployment.yaml iac/main.tf iac/main-open.tf
    st=$(wait_run 2)
    [ "$st" = "2" ] || fail "安全违规应 Failure，实为 $(status_name "$st")"
    ok "gate2 拦下（run status=Failure）"

    note "[场景 3] 凭证泄漏（明文口令默认值）→ gate3 gitleaks 应拦"
    seed_and_push manifests/deployment.yaml iac/main.tf iac/secret-leak.tf
    st=$(wait_run 2)
    [ "$st" = "2" ] || fail "凭证泄漏应 Failure，实为 $(status_name "$st")"
    ok "gate3 拦下（run status=Failure）"
}

do_clean() {
    step clean "销毁"
    docker rm -f "$G" "$R" >/dev/null 2>&1 || true
    docker rm -f $(docker ps -aq --filter name=act-lab25 2>/dev/null) >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker volume rm -f lab25-gitea-data >/dev/null 2>&1 || true
    rm -rf "$REPO"
    docker rmi "$JOBIMG" >/dev/null 2>&1 || true
    rm -f citools/conftest citools/trivy citools/gitleaks citools/*.tgz
    ! docker ps -a --format '{{.Names}}' | grep -qE "^lab25" && note "[ok] 零残留" || { note "[!] 残留" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)    do_up ;;
        green) do_green ;;
        red)   do_red ;;
        clean) do_clean ;;
        all)   do_up; do_green; do_red; do_clean ;;
        *) echo "可用: up | green | red | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
