#!/usr/bin/env bash
# =============================================================================
# 03 · Stack 与配置 — 主演示脚本
#
# 完整生命周期：apply → observe → stacks(隔离+rm) → rotate(密钥轮换) → clean
# 用法：
#   ./stack_config.sh apply    # 同一程序建 dev/prod 两个 stack 并各自 up
#   ./stack_config.sh observe  # 配置读法 + "密文三层"证据
#   ./stack_config.sh stacks   # 隔离验证（destroy dev，prod 不动）+ stack rm 演示
#   ./stack_config.sh rotate   # 只改 dev 的 secret，观察定向更新
#   ./stack_config.sh clean    # 两栈 destroy 全清，无残留
#   ./stack_config.sh          # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# Go 类客户端不认 docker context，显式选一个响应正常的 socket（见 scripts/docker-env.sh）
. "../../scripts/docker-env.sh"

# 本地文件后端 + 固定口令（口令同时是 secret 的解密钥匙，见 README 的密钥边界一节）
export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1

PU="pulumi -C program"
LOGS=".logs"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# run <name> <pulumi 子命令...>：执行并留档（先落档再断言，不在活管道上 grep）
run() {
    local name="$1"; shift
    mkdir -p "$LOGS"
    $PU "$@" 2>&1 | tee "$LOGS/$name.log"
}

# 轮询等待 HTTP 就绪（不裸 sleep）
wait_http() {
    local url="$1" i=0
    until curl -fsS -o /dev/null "$url" 2>/dev/null; do
        i=$((i+1)); [ "$i" -gt 15 ] && { echo "    [!] 15s 内 $url 未就绪" >&2; return 1; }
        sleep 1
    done
}

# 断言某端口后面确实是 nginx 欢迎页（先取回内容再 grep，避开活管道 SIGPIPE）
check_nginx() {
    local body
    body=$(curl -fsS "http://localhost:$1/")
    grep -q "Welcome to nginx" <<<"$body" \
        || { echo "    [x] 端口 $1 不是 nginx 首页——被别的服务占了？" >&2; exit 1; }
}

# 容器环境变量里某键的值
container_env() { # $1=容器名 $2=变量名
    docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^$2=" | cut -d= -f2-
}

ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    if [ ! -d program/node_modules ]; then
        note "首次运行：安装 TS 依赖（npm install，约 1 分钟）"
        (cd program && npm install --loglevel=error)
    fi
    mkdir -p .pulumi-state
}

# init_stack <name> <port> <image> <greeting>：建栈（或复用）+ 幂等写入配置
init_stack() {
    local name="$1" port="$2" image="$3" greeting="$4"
    if ! $PU stack select "$name" >/dev/null 2>&1; then
        $PU stack init "$name" >/dev/null
        note "已创建栈 $name"
    fi
    $PU config set port "$port" --stack "$name" >/dev/null
    $PU config set image "$image" --stack "$name" >/dev/null
    $PU config set --secret greeting "$greeting" --stack "$name" >/dev/null
}

do_apply() {
    step "apply" "同一份程序，两个 stack 各建一套环境（配置不同、账本独立）"
    ensure_ready
    init_stack dev  28201 nginx:1.27-alpine dev-greeting-secret
    init_stack prod 28202 nginx:1.25-alpine prod-greeting-secret
    run up-dev up --stack dev --yes
    grep -q "\[secret\]" "$LOGS/up-dev.log" \
        || { echo "    [!] up 输出里未见 [secret] 打码" >&2; exit 1; }
    note "[ok] up 输出对 secret 打码（greeting: [secret]）"
    run up-prod up --stack prod --yes
    docker ps --filter "name=pulumi03" --format "        {{.Names}}  {{.Image}}  {{.Ports}}"
    [ "$(docker inspect pulumi03-dev-web  --format '{{.Config.Image}}')" = "nginx:1.27-alpine" ] \
        || { echo "    [!] dev 镜像不对" >&2; exit 1; }
    [ "$(docker inspect pulumi03-prod-web --format '{{.Config.Image}}')" = "nginx:1.25-alpine" ] \
        || { echo "    [!] prod 镜像不对" >&2; exit 1; }
    wait_http http://localhost:28201/; check_nginx 28201
    wait_http http://localhost:28202/; check_nginx 28202
    note "[ok] dev/prod 各一套：端口/镜像不同，互不撞名"
}

do_observe() {
    step "observe" "配置读法 + \"密文三层\"证据"
    note "pulumi stack ls —— 两个栈，各自独立的资源计数"
    $PU stack ls | sed 's/^/        /'
    note "pulumi config 表格 —— secret 项打码为 [secret]"
    $PU config --stack dev | sed 's/^/        /'
    note "但 pulumi config get 会直接打印明文（CLI 给你自己看；保护的是文件与 state）："
    note "        greeting = $($PU config get greeting --stack dev)"
    note "① Pulumi.dev.yaml 里的形态（密文）："
    grep -A2 "greeting:" program/Pulumi.dev.yaml | sed 's/^/        /'
    note "② 全量扫描：明文在 yaml 与 state 的零命中（at rest 全程密文）"
    if grep -q "dev-greeting-secret" program/Pulumi.dev.yaml; then
        echo "    [!] Pulumi.dev.yaml 泄漏明文" >&2; exit 1
    fi
    if grep -rq "dev-greeting-secret" .pulumi-state/; then
        echo "    [!] state 目录泄漏明文" >&2; exit 1
    fi
    note "[ok] Pulumi.dev.yaml 与 .pulumi-state/ 明文 0 命中"
    note "③ 部署时解密注入到容器环境（运行时才可见）："
    note "        dev-web  SITE_GREETING=$(container_env pulumi03-dev-web SITE_GREETING)"
}

do_stacks() {
    step "stacks" "隔离验证：销毁 dev，prod 毫发无损"
    run destroy-dev destroy --stack dev --yes
    if docker ps --filter "name=pulumi03-dev-web" -q | grep -q .; then
        echo "    [!] dev 容器应该已被销毁" >&2; exit 1
    fi
    docker ps --filter "name=pulumi03-prod-web" -q | grep -q . \
        || { echo "    [!] prod 容器竟然被波及" >&2; exit 1; }
    note "[ok] dev 容器已销毁；prod 仍在运行（curl 验证：）"
    check_nginx 28202
    note "[ok] prod 服务不受影响——两个 stack 账本独立，互不干扰"
    note "恢复 dev："
    run up-dev-restore up --stack dev --yes
    wait_http http://localhost:28201/; check_nginx 28201
    note "[ok] dev 已按自己的配置重建"
    note "带资源的栈直接 rm 会被拒绝（实测）："
    if $PU stack rm dev --yes >"$LOGS/rm-reject.log" 2>&1; then
        echo "    [!] 带资源的栈竟然 rm 成功了" >&2; exit 1
    fi
    grep -q "still has resources" "$LOGS/rm-reject.log" \
        || { echo "    [!] 拒绝原因不是预期的 still has resources" >&2; exit 1; }
    note "[ok] 拒绝信息：$(head -1 "$LOGS/rm-reject.log")"
    note "空栈的 rm 演示（scratch：init → ls → rm）："
    $PU stack init scratch >/dev/null
    $PU stack ls | sed 's/^/        /'
    $PU stack rm scratch --yes >/dev/null
    note "[ok] scratch 已移除，回到 dev / prod 两栈"
}

do_rotate() {
    step "rotate" "密钥轮换：改一处配置，只更新该 stack 的容器"
    $PU config set --secret greeting "dev-greeting-rotated" --stack dev >/dev/null
    note "dev 的 greeting 已换新值（Pulumi.dev.yaml 中是另一段密文）"
    run up-rotate up --stack dev --yes
    grep -q "replace" "$LOGS/up-rotate.log" \
        || { echo "    [!] 未见容器替换动作" >&2; exit 1; }
    note "[ok] 容器按新 secret 替换（diff 只显示 ~envs，不显示明文）"
    [ "$(container_env pulumi03-dev-web SITE_GREETING)" = "dev-greeting-rotated" ] \
        || { echo "    [!] dev 容器未拿到新值" >&2; exit 1; }
    [ "$(container_env pulumi03-prod-web SITE_GREETING)" = "prod-greeting-secret" ] \
        || { echo "    [!] prod 竟然被动了" >&2; exit 1; }
    note "[ok] dev 已轮换到位；prod 原值不动"
}

do_clean() {
    step "clean" "两栈 destroy 全清 + 残留断言"
    local s
    for s in dev prod; do
        if $PU stack select "$s" >/dev/null 2>&1; then
            run "destroy-$s" destroy --stack "$s" --yes
        fi
    done
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep '^pulumi03' || true)
    if [ -z "$leftover" ]; then
        note "[ok] 容器零残留，回到实验前状态"
    else
        note "[!] 有残留：$leftover" >&2
        return 1
    fi
    rm -rf "$LOGS"
    note "日志已清；state 与 Pulumi.*.yaml 保留（配置与账本是项目资产，不是运行时垃圾）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)   do_apply ;;
        observe) do_observe ;;
        stacks)  do_stacks ;;
        rotate)  do_rotate ;;
        clean)   do_clean ;;
        all)     do_apply; do_observe; do_stacks; do_rotate; do_clean ;;
        *) echo "可用: apply | observe | stacks | rotate | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
