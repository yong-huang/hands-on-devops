#!/usr/bin/env bash
# =============================================================================
# 05 · ComponentResource（对标 TF module）— 主演示脚本
#
# 完整生命周期：apply → urns → evolve → clean
# 用法：
#   ./component_resource.sh apply    # 组件实例化两套服务（各自网络+容器）
#   ./component_resource.sh urns     # stack 导出里的 URN 父子树（资源挂在组件下）
#   ./component_resource.sh evolve   # 改组件一行 → 两实例同步更新（trap 自动还原源码）
#   ./component_resource.sh clean    # 销毁全清，零残留
#   ./component_resource.sh          # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# Go 类客户端不认 docker context，显式选一个响应正常的 socket（见 scripts/docker-env.sh）
. "../../scripts/docker-env.sh"

# 本地文件后端 + 固定口令（见实验 03/04）
export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1

PU="pulumi -C program"
LOGS=".logs"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

run() {
    local name="$1"; shift
    mkdir -p "$LOGS"
    $PU "$@" 2>&1 | tee "$LOGS/$name.log"
}

wait_http() {
    local url="$1" i=0
    until curl -fsS -o /dev/null "$url" 2>/dev/null; do
        i=$((i+1)); [ "$i" -gt 15 ] && { echo "    [!] 15s 内 $url 未就绪" >&2; return 1; }
        sleep 1
    done
}

check_nginx() {
    local body
    body=$(curl -fsS "http://localhost:$1/")
    grep -q "Welcome to nginx" <<<"$body" \
        || { echo "    [x] 端口 $1 不是 nginx 首页——被别的服务占了？" >&2; exit 1; }
}

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

ensure_stack() {
    if ! $PU stack select dev >/dev/null 2>&1; then
        $PU stack init dev >/dev/null
        note "已创建栈 dev"
    fi
}

# 从 stack export 打印 URN 父子树；断言容器都挂在 WebService 组件下
# （state 的每个资源都带 parent 字段——父子关系写在账本里，不靠命名约定）
print_urn_tree() {
    python3 - "$LOGS/state-export.json" <<'PY'
import json, sys, subprocess

d = json.load(open(sys.argv[1]))
res = d["deployment"]["resources"]
by_urn = {r["urn"]: r for r in res}

def kids(urn):
    return [r for r in res if r.get("parent") == urn
            and not r["type"].startswith("pulumi:providers")]

def short(urn):
    parts = urn.split("::")
    return f"{parts[-2]}::{parts[-1]}"

stack = next(r for r in res if r["type"] == "pulumi:pulumi:Stack")
def walk(urn, depth=0):
    for r in sorted(kids(urn), key=lambda x: x["urn"]):
        print("        " + "    " * depth + "└─ " + short(r["urn"]))
        walk(r["urn"], depth + 1)

walk(stack["urn"])

# 断言：每个容器都挂在 WebService 组件下（parent 是组件的 URN）
containers = [r for r in res if r["type"] == "docker:index/container:Container"]
assert containers, "账本里没有容器"
for c in containers:
    p = by_urn[c["parent"]]
    assert p["type"] == "hands-on:service:WebService", \
        f"容器 {c['urn']} 的 parent 不是 WebService 组件"
print("        [ok] 全部容器的 parent 都指向 WebService 组件——父子树写在账本里")
PY
}

do_apply() {
    step "apply" "一个组件类，实例化两套服务（alpha :28401 / beta :28402）"
    ensure_ready
    ensure_stack
    run up up --stack dev --yes
    if grep -q "created" "$LOGS/up.log"; then
        note "[ok] 创建完成"
    elif grep -q "unchanged" "$LOGS/up.log"; then
        note "[ok] 已在期望态（零变更，重跑幂等）"
    else
        echo "    [!] up 结果异常，看 ${LOGS}/up.log" >&2; exit 1
    fi
    docker ps --filter "name=pulumi05" --format "        {{.Names}}  {{.Image}}  {{.Ports}}"
    [ "$(docker inspect pulumi05-alpha-web --format '{{.Config.Image}}')" = "nginx:1.27-alpine" ] \
        || { echo "    [!] alpha 镜像不对" >&2; exit 1; }
    [ "$(docker inspect pulumi05-beta-web --format '{{.Config.Image}}')" = "nginx:1.25-alpine" ] \
        || { echo "    [!] beta 镜像不对" >&2; exit 1; }
    wait_http http://localhost:28401/; check_nginx 28401
    wait_http http://localhost:28402/; check_nginx 28402
    note "[ok] 两套服务各就各位：同一段组件代码，两组参数"
}

do_urns() {
    step "urns" "URN 父子树：资源挂在组件下（state 里的 parent 字段）"
    $PU stack export --stack dev 2>/dev/null > "$LOGS/state-export.json"
    note "pulumi stack --show-urns（组件本身也是一条资源）："
    $PU stack --show-urns --stack dev 2>&1 | sed 's/^/        /' | head -20
    note "账本里的父子树（parent → 子资源）："
    print_urn_tree
}

do_evolve() {
    step "evolve" "改组件一行 → 两实例同步更新（源文件带 trap 守护，自动还原）"
    local src="program/component.ts" backup="$LOGS/component.ts.bak"
    mkdir -p "$LOGS"
    cp "$src" "$backup"
    trap 'mv "$backup" "$src"' EXIT
    # 在组件内部的容器声明里加一个环境变量——调用方 index.ts 一行不动
    sed -i '' 's|image: args.image,|image: args.image,\n            envs: ["COMPONENT_VERSION=v2"],|' "$src"
    if ! grep -q "COMPONENT_VERSION" "$src"; then
        echo "    [!] 组件源码改写失败" >&2; exit 1
    fi
    note "组件 component.ts 加了一行 envs，index.ts 零改动——up："
    run up-evolve up --stack dev --yes
    [ "$(grep -c '\[diff: +envs\]' "$LOGS/up-evolve.log")" -ge 4 ] \
        || { echo "    [!] diff 里未见两实例的 envs 变更" >&2; exit 1; }
    [ "$(container_env pulumi05-alpha-web COMPONENT_VERSION)" = "v2" ] \
        || { echo "    [!] alpha 未拿到组件新版本" >&2; exit 1; }
    [ "$(container_env pulumi05-beta-web COMPONENT_VERSION)" = "v2" ] \
        || { echo "    [!] beta 未拿到组件新版本" >&2; exit 1; }
    note "[ok] alpha 与 beta 一起拿到 COMPONENT_VERSION=v2——改一处，处处生效"
    wait_http http://localhost:28401/; check_nginx 28401
    wait_http http://localhost:28402/; check_nginx 28402
    note "[ok] 两套服务替换后照常服务"
    trap - EXIT
    mv "$backup" "$src"
    note "组件源码已还原（下一次 up 会看到 2 个 replace，回到 v1 期望态）"
}

do_clean() {
    step "clean" "销毁全清 + 零残留断言"
    if $PU stack select dev >/dev/null 2>&1; then
        run destroy destroy --stack dev --yes
    fi
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep '^pulumi05' || true)
    if [ -z "$leftover" ]; then
        note "[ok] 容器/网络零残留，回到实验前状态"
    else
        note "[!] 有残留：$leftover" >&2
        return 1
    fi
    rm -rf "$LOGS"
    note "日志已清；state 与 Pulumi.yaml 保留（配置与账本是项目资产）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)  do_apply ;;
        urns)   do_urns ;;
        evolve) do_evolve ;;
        clean)  do_clean ;;
        all)    do_apply; do_urns; do_evolve; do_clean ;;
        *) echo "可用: apply | urns | evolve | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
