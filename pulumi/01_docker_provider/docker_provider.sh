#!/usr/bin/env bash
# =============================================================================
# 01 · Pulumi Docker Provider — 主演示脚本
#
# 完整生命周期：apply → observe → drift(注入漂移+检出+回正) → clean
# 用法：
#   ./docker_provider.sh apply    # 创建：自定义网络 + nginx 容器
#   ./docker_provider.sh observe  # pulumi stack / docker ps / state 文件 三方对照
#   ./docker_provider.sh drift    # rm 容器 → 裸 preview 看不见 → refresh 检出 → up 回正
#   ./docker_provider.sh clean    # destroy 全清，无残留
#   ./docker_provider.sh          # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# Go 类客户端不认 docker context，显式选一个响应正常的 socket（见 scripts/docker-env.sh）
. "../../scripts/docker-env.sh"

# 本地文件后端：state 落在实验目录 .pulumi-state/，不碰云端、不污染全局配置。
# （Pulumi 默认后端是 Pulumi Cloud，需要账号登录；本系列零云，一律用本地后端。）
export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"
# DIY 后端需要一个口令来加密 state 里的敏感值；实验里用固定口令，真实姿势见实验 3。
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
# 跳过联网的版本检查（离线友好）
export PULUMI_SKIP_UPDATE_CHECK=1

PU="pulumi -C program"    # -C 等价于 terraform -chdir=：程序目录独立，脚本随处可跑
STATE_STACKS=".pulumi-state/.pulumi/stacks/pulumi01-docker-provider"
LOGS=".logs"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# run <name> <pulumi 子命令...>：执行并留档到 $LOGS/<name>.log。
# 坑：不要断言活管道（grep -q 命中即退会把 tee 挤成 SIGPIPE）——先落档、再对文件断言。
run() {
    local name="$1"; shift
    mkdir -p "$LOGS"
    $PU "$@" 2>&1 | tee "$LOGS/$name.log"
}

# 轮询等待 HTTP 就绪（不裸 sleep）；-o /dev/null 只看连通性
wait_http() {
    local url="http://localhost:28081/" i=0
    until curl -fsS -o /dev/null "$url" 2>/dev/null; do
        i=$((i+1)); [ "$i" -gt 15 ] && { echo "    [!] 15s 内 $url 未就绪" >&2; return 1; }
        sleep 1
    done
}

# 容器挂的网络名（空输出即没挂上）
container_network() {
    docker inspect pulumi01-nginx \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null
}

# 首次运行准备：CLI 存在 → npm 依赖 → 后端目录 → dev 栈
ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    if [ ! -d program/node_modules ]; then
        note "首次运行：安装 TS 依赖（npm install，约 1 分钟）"
        (cd program && npm install --loglevel=error)
    fi
    mkdir -p .pulumi-state    # 本地后端要求目录先存在，否则 stack init 报 stat 错误
    if ! $PU stack select dev >/dev/null 2>&1; then
        $PU stack init dev >/dev/null
        note "已创建本地栈 dev（state 落在 $PULUMI_BACKEND_URL）"
    fi
}

do_apply() {
    step "apply" "创建：自定义网络 + nginx 容器（首次会下载 docker provider 插件）"
    ensure_ready
    run up up --yes
    note "pulumi up 返回后，用 docker 视角验证真实结果："
    docker ps --filter "name=pulumi01-nginx" --format "        {{.Names}}  {{.Status}}  {{.Ports}}"
    [ "$(container_network)" = "pulumi01-net" ] \
        || { echo "    [!] 容器没挂到 pulumi01-net" >&2; exit 1; }
    note "[ok] 容器在自定义网络 $(container_network) 里"
    wait_http
    local body
    body=$(curl -fsS http://localhost:28081/)
    grep -q "<title>Welcome to nginx!</title>" <<<"$body" \
        || { echo "    [x] 28081 返回的不是 nginx 首页——端口被别的服务占了？" >&2; exit 1; }
    note "[ok] curl 命中 nginx 欢迎页"
}

do_observe() {
    step "observe" "Pulumi 视角 vs Docker 视角，同一批资源"
    note "pulumi stack —— state 记账本里的资源树"
    $PU stack | sed 's/^/        /'
    note "docker ps 对照（真名前缀 pulumi01 来自程序里的 appName 常量）"
    docker ps --filter "name=pulumi01" --format "        {{.Names}}\t{{.Status}}\t{{.Ports}}"
    note "state 记账本的实体文件（打开看是 JSON）："
    ls -1 "$STATE_STACKS" 2>/dev/null | sed 's/^/        /' \
        || { echo "    [!] 找不到 state 文件——先跑 apply" >&2; exit 1; }
    note "幂等验证：再次 preview 应为 0 变更（--expect-no-changes 用退出码断言）"
    if $PU preview --expect-no-changes >/dev/null 2>&1; then
        note "[ok] exit=0：与期望态完全一致"
    else
        echo "    [!] preview 出现意外变更" >&2; exit 1
    fi
}

do_drift() {
    step "drift" "有人手动删了容器——Pulumi 多久能发现？"
    note "模拟手工操作：docker rm -f pulumi01-nginx"
    docker rm -f pulumi01-nginx >/dev/null
    note "① 裸 preview：state 记账本没坏，它说『一切正常』——Pulumi 默认不刷新实际状态"
    run preview-blind preview
    grep -q "unchanged" "$LOGS/preview-blind.log" \
        || { echo "    [!] 裸 preview 输出不符合预期" >&2; exit 1; }
    note "    （这点与 Terraform plan 默认 refresh 的习惯不同，是本实验最值得记的差异）"
    note "② pulumi refresh：拿 daemon 实际状态与账本对账，检出『容器已消失』"
    run refresh refresh --yes
    grep -q "delete" "$LOGS/refresh.log" \
        || { echo "    [!] refresh 未检出删除" >&2; exit 1; }
    note "[检出] refresh 把删除写回 state（明细见 $LOGS/refresh.log）"
    note "③ pulumi up：按期望态重建（自愈）"
    run up-heal up --yes
    wait_http
    local body
    body=$(curl -fsS http://localhost:28081/)
    grep -q "Welcome to nginx" <<<"$body" \
        || { echo "    [!] 恢复后服务不可用" >&2; exit 1; }
    note "[ok] 容器重建、服务恢复——期望态就是自愈的判据"
}

do_clean() {
    step "clean" "destroy 全清 + 残留断言"
    if $PU stack select dev >/dev/null 2>&1; then
        run destroy destroy --yes
    else
        note "栈不存在（没跑过 apply），直接做残留清理"
    fi
    local leftover nets
    leftover=$(docker ps -a --format '{{.Names}}' | grep '^pulumi01' || true)
    nets=$(docker network ls --format '{{.Name}}' | grep '^pulumi01' || true)
    if [ -z "$leftover" ] && [ -z "$nets" ]; then
        note "[ok] 容器/网络零残留，回到实验前状态"
    else
        note "[!] 有残留：${leftover:-} ${nets:-}" >&2
        return 1
    fi
    rm -rf "$LOGS"
    note "日志已清；state 记账本 .pulumi-state/ 保留（按 Docker 惯例：destroy 后是空栈，下次 apply 直接复用）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)   do_apply ;;
        observe) do_observe ;;
        drift)   do_drift ;;
        clean)   do_clean ;;
        all)     do_apply; do_observe; do_drift; do_clean ;;
        *) echo "可用: apply | observe | drift | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
