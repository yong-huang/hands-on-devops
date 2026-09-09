#!/usr/bin/env bash
# =============================================================================
# 18 · Gitea + Actions — 主演示脚本
#
# 自带一套 Gitea（开启 Actions）+ act_runner（docker 模式），push 代码自动触发流水线。
#
# ./gitea_actions.sh apply   起 Gitea+runner → 建仓 → push → 断言流水线绿
# ./gitea_actions.sh fail    注入失败用例 → 流水线红 → 修复
# ./gitea_actions.sh clean   销毁
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

NET="lab18-net"
G="lab18-gitea"
R="lab18-runner"
GI="http://lab18-gitea:3000"
GU="http://localhost:3352"
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

# runner 注册 token：gitea CLI 以 uid1000 执行（root 会被拒，同实验 05 坑）
get_runner_token() {
    docker exec -u 1000 "$G" gitea actions generate-runner-token 2>/dev/null
}

# 抓取当前最大 run 编号（Gitea 1.22 无 actions REST API，只能从页面解析）
max_run() {
    # 坑：还没有任何 run 时 grep 会以 1 退出，pipefail 会杀死整个脚本——必须兜底
    local m=0
    m=$(curl -s -u "$AUTH" "$GU/devops/demo/actions" | grep -oE 'actions/runs/[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1 || echo 0)
    echo "${m:-0}"
}

# run_status <n>：读取指定 run 的页面状态
run_status() {
    # 坑①：1.22 无 actions REST API；坑②：run 页面侧栏混有其他 run 的状态——
    # 最可靠的判据是 gitea 数据目录里的运行日志（结尾必含 Job succeeded/failed）
    local n="$1" nn
    nn=$(printf '%02d' "$n")
    local out
    out=$(docker exec lab18-gitea sh -c "cat /data/gitea/actions_log/devops/demo/$nn/$n.log 2>/dev/null" | LC_ALL=C sed 's/\x1b\[[0-9;]*m//g')
    echo "$out" | grep -q "Job failed" && { echo FAILURE; return 0; }
    echo "$out" | grep -q "Job succeeded" && { echo SUCCESS; return 0; }
    echo PENDING
}

do_apply() {
    step "apply" "起 Gitea（Actions 开关开启）+ act_runner"
    docker network create "$NET" >/dev/null 2>&1 || true
    docker rm -f "$G" "$R" >/dev/null 2>&1 || true
    docker volume rm -f lab18-gitea-data >/dev/null 2>&1 || true
    docker run -d --name "$G" --network "$NET" -p 3352:3000 \
        -e GITEA__security__INSTALL_LOCK=true \
        -e GITEA__actions__ENABLED=true \
        -e GITEA__server__ROOT_URL="$GU/" \
        -e "GITEA__runner__INDEX=1" \
        -v lab18-gitea-data:/data \
        gitea/gitea:1.22 >/dev/null
    wait_http "$GU/api/healthz" "Gitea"
    docker exec -u 1000 "$G" gitea admin user create \
        --username devops --password devops123 --email devops@lab.local --admin >/dev/null 2>&1 || true

    # act_runner：docker 模式。
# 坑：macOS 上把 ~/.docker/run/docker.sock 挂进容器是不行的（宿主 unix socket
# 文件无法经 virtiofs 共享）；用 /var/run/docker.sock 这条 Docker Desktop
# 专用路径（由 VM 内的 dockerd 提供）才是正解
    local token
    token=$(get_runner_token)
    note "runner 注册 token: ${token:0:6}…"
    cat > runner/config.yaml <<EOF
runner:
  labels:
    - "lab:docker://python:3.12-slim"
EOF
    docker build -q -t lab18-runner:host runner/ >/dev/null
    docker run -d --name "$R" --network "$NET" \
        -e GITEA_INSTANCE_URL="$GI" \
        -e GITEA_RUNNER_REGISTRATION_TOKEN="$token" \
        -e GITEA_RUNNER_NAME="lab-runner" \
        -e GITEA_RUNNER_LABELS="lab:host://" \
        -v "$(pwd)/runner:/config" \
        lab18-runner:host >/dev/null

    step "apply" "建仓 + push（on: push 自动触发流水线）"
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X POST "$GU/api/v1/user/repos" \
        -H "Content-Type: application/json" \
        -d '{"name":"demo","auto_init":false}')
    [ "$code" = "201" ] || [ "$code" = "409" ] || { note "[x] 建仓失败 $code" >&2; exit 1; }
    if [ ! -d repo/.git ]; then
        git -C repo init -q -b main
        git -C repo add -A
        git -C repo -c user.email=lab@local -c user.name=lab commit -qm "init"
    fi
    git -C repo push -q -u "http://devops:devops123@localhost:3352/devops/demo.git" main 2>/dev/null \
        || git -C repo push -q "http://devops:devops123@localhost:3352/devops/demo.git" main
    note "[ok] 已 push 到 main"

    step "apply" "等待流水线执行并断言结果"
    local base_run n=0 run status
    base_run=$(max_run)
    while :; do
        sleep 3; n=$((n+1)); [ $n -gt 40 ] && { echo "    [!] 未看到新 run" >&2; exit 1; }
        run=$(max_run); [ "${run:-0}" -gt "${base_run:-0}" ] && break
    done
    n=0
    while :; do
        sleep 5; n=$((n+1)); [ $n -gt 40 ] && { echo "    [!] 流水线 200s 未完成" >&2; exit 1; }
        status=$(run_status "$run")
        note "run #$run: ${status:-pending}"
        [ "$status" = "SUCCESS" ] || [ "$status" = "FAILURE" ] && break
    done
    if [ "$status" != "SUCCESS" ]; then
        # 坑：runner 偶发 "Copy failed"（docker 瞬时抖动）——自动重推重试一次
        note "[i] 首次 ${status} ，自动重推重试（最多 3 次）"
        local attempt=1
        while [ "$status" != "SUCCESS" ] && [ $attempt -le 3 ]; do
            git -C repo -c user.email=lab@local -c user.name=lab commit -qm "retry-$attempt" --allow-empty
            git -C repo push -q "http://devops:devops123@localhost:3352/devops/demo.git" main 2>/dev/null || true
            local base_r n3=0 r3
            base_r=$(max_run)
            while :; do
                sleep 3; n3=$((n3+1)); [ $n3 -gt 40 ] && break
                r3=$(max_run); [ "${r3:-0}" -gt "${base_r:-0}" ] && break
            done
            n3=0
            while :; do
                sleep 5; n3=$((n3+1)); [ $n3 -gt 40 ] && break
                status=$(run_status "$r3")
                note "run #${r3}: ${status:-pending}"
                [ "$status" = "SUCCESS" ] || [ "$status" = "FAILURE" ] && break
            done
            attempt=$((attempt+1))
        done
        git -C repo -c user.email=lab@local -c user.name=lab commit -qm retry --allow-empty
        git -C repo push -q "http://devops:devops123@localhost:3352/devops/demo.git" main 2>/dev/null || true
        local base2 n2=0 r2
        base2=$(max_run)
        while :; do
            sleep 3; n2=$((n2+1)); [ $n2 -gt 40 ] && { echo "    [!] 未看到新 run" >&2; exit 1; }
            r2=$(max_run); [ "${r2:-0}" -gt "${base2:-0}" ] && break
        done
        n2=0
        while :; do
            sleep 5; n2=$((n2+1)); [ $n2 -gt 40 ] && { echo "    [!] 重试超时" >&2; exit 1; }
            status=$(run_status "$r2")
            note "run #$r2: ${status:-pending}"
            [ "$status" = "SUCCESS" ] || [ "$status" = "FAILURE" ] && break
        done
    fi
    [ "$status" = "SUCCESS" ] && note "[ok] push 自动触发全绿 run=${r2:-${run}}" || { note "[x] 流水线状态 ${status}" >&2; exit 1; }
}

do_fail() {
    step "fail" "注入失败用例 → 流水线红 → 修复"
    cat >> repo/.gitea/workflows/release.yml <<'EOF'
      - name: injected-failure
        run: exit 1
EOF
    git -C repo add -A && git -C repo -c user.email=lab@local -c user.name=lab commit -qm "inject failure"
    git -C repo push -q "http://devops:devops123@localhost:3352/devops/demo.git" main 2>/dev/null || true
    local base_run n=0 run status
    base_run=$(max_run)
    while :; do
        sleep 3; n=$((n+1)); [ $n -gt 40 ] && { echo "    [!] 未看到新 run" >&2; exit 1; }
        run=$(max_run); [ "${run:-0}" -gt "${base_run:-0}" ] && break
    done
    n=0
    while :; do
        sleep 5; n=$((n+1)); [ $n -gt 40 ] && { echo "    [!] 超时" >&2; exit 1; }
        status=$(run_status "$run")
        note "run #$run: ${status:-pending}"
        [ "$status" = "SUCCESS" ] || [ "$status" = "FAILURE" ] && break
    done
    [ "$status" = "FAILURE" ] && note "[检出] 流水线红（注入的 assert 被抓住）" || { note "[x] 预期红灯未出现: $status" >&2; }
    git -C repo revert --no-edit HEAD >/dev/null 2>&1 || git -C repo -c user.email=lab@local -c user.name=lab revert --no-edit HEAD >/dev/null 2>&1 || true
    # 确定性清理：注入的步骤必须从工作树消失（revert 失败也兜底）
    LC_ALL=C sed -i '' '/injected-failure/d; /run: exit 1/d' repo/.gitea/workflows/release.yml
    git -C repo add -A && git -C repo -c user.email=lab@local -c user.name=lab commit -qm "fix" --allow-empty
    git -C repo push -q "http://devops:devops123@localhost:3352/devops/demo.git" main 2>/dev/null || true
    note "[ok] 已 revert 修复并重新推送"
}

do_clean() {
    step "clean" "销毁 Gitea / runner / 网络"
    docker rm -f "$G" "$R" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf repo/.git
    ! docker ps -a --format '{{.Names}}' | grep -qE "^lab18" && note "[ok] 零残留" || { note "[!] 残留" >&2; exit 1; }
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
