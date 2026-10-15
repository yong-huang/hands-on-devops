#!/usr/bin/env bash
# =============================================================================
# 02 · 编程语言的力量 — 主演示脚本
#
# 完整生命周期：apply → observe → scale(2→3→2) → fail(类型拦截) → clean
# 用法：
#   ./language_features.sh apply    # 从数组创建 2 个站点
#   ./language_features.sh observe  # 资源清单 + tsc 类型检查
#   ./language_features.sh scale    # 数组 2→3→2：观察"只动差集"的增量收敛
#   ./language_features.sh fail     # 故意写错类型，tsc 必须在部署前拦住
#   ./language_features.sh clean    # destroy 全清，无残留
#   ./language_features.sh          # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# Go 类客户端不认 docker context，显式选一个响应正常的 socket（见 scripts/docker-env.sh）
. "../../scripts/docker-env.sh"

# 本地文件后端 + 固定口令（与项目 1 一致；真实项目的密钥治理见实验 3 / 24）
export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1

PU="pulumi -C program"
LOGS=".logs"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# scale / fail 段会临时改写源文件；中断也要还原（幂等，可在任意时刻安全重跑）
restore_sources() {
    if [ -f program/.sites.ts.bak ]; then mv program/.sites.ts.bak program/sites.ts; fi
    if [ -f program/.index.ts.bak ]; then mv program/.index.ts.bak program/index.ts; fi
    return 0
}
trap restore_sources EXIT

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

# 运行中的站点容器数
count_sites() { docker ps --filter "name=pulumi02-" -q | wc -l | tr -d ' '; }

# 断言某端口后面确实是 nginx 欢迎页（先取回内容再 grep，避开活管道 SIGPIPE）
check_nginx() {
    local body
    body=$(curl -fsS "http://localhost:$1/")
    grep -q "Welcome to nginx" <<<"$body" \
        || { echo "    [x] 端口 $1 不是 nginx 首页——被别的服务占了？" >&2; exit 1; }
}

ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    if [ ! -d program/node_modules ]; then
        note "首次运行：安装 TS 依赖（npm install，约 1 分钟）"
        (cd program && npm install --loglevel=error)
    fi
    mkdir -p .pulumi-state
    if ! $PU stack select dev >/dev/null 2>&1; then
        $PU stack init dev >/dev/null
        note "已创建本地栈 dev（state 落在 $PULUMI_BACKEND_URL）"
    fi
}

do_apply() {
    step "apply" "从数组创建 2 个站点（同一循环，无依赖的容器并行创建）"
    ensure_ready
    run up up --yes
    docker ps --filter "name=pulumi02" --format "        {{.Names}}  {{.Status}}  {{.Ports}}"
    [ "$(count_sites)" = "2" ] || { echo "    [!] 期望 2 个站点，实际 $(count_sites)" >&2; exit 1; }
    note "条件表达式的效果——两个站点拿到了不同的镜像 tag："
    docker inspect pulumi02-alpha --format '        alpha -> {{.Config.Image}}'
    docker inspect pulumi02-beta  --format '        beta  -> {{.Config.Image}}'
    [ "$(docker inspect pulumi02-beta --format '{{.Config.Image}}')" = "nginx:1.25-alpine" ] \
        || { echo "    [!] beta 未按 preview 条件拿到 1.25 镜像" >&2; exit 1; }
    wait_http http://localhost:28091/; check_nginx 28091
    wait_http http://localhost:28092/; check_nginx 28092
    note "[ok] 两个站点就绪（beta 走 preview 分支）"
}

do_observe() {
    step "observe" "程序结构 ↔ 资源清单：循环里的 site-<name> 就是资源逻辑名"
    $PU stack | sed 's/^/        /'
    note "tsc 类型检查（strict 全开，部署前的第一道防线）："
    if (cd program && npx tsc --noEmit --pretty false) >"$LOGS/tsc.log" 2>&1; then
        note "[ok] npx tsc --noEmit 零错误"
    else
        sed 's/^/        /' "$LOGS/tsc.log"
        echo "    [!] 类型检查未通过" >&2; exit 1
    fi
}

do_scale() {
    step "scale" "数组 2 → 3：Pulumi 只创建差集，还是推倒重来？"
    cp program/sites.ts program/.sites.ts.bak
    cat > program/sites.ts <<'EOF'
// sites.ts —— 站点清单（scale 段自动生成的 3 站点版本，跑完自动还原）
export interface Site {
    name: string;
    port: number;
    channel: "stable" | "preview";
}

export const WEB_SITES: Site[] = [
    { name: "alpha", port: 28091, channel: "stable" },
    { name: "beta", port: 28092, channel: "preview" },
    { name: "gamma", port: 28093, channel: "stable" },
];
EOF
    note "sites.ts 已换成 3 站点版本，再 up："
    run scale-up up --yes
    grep -q "+ 1 created" "$LOGS/scale-up.log" \
        || { echo "    [!] 未观察到『+ 1 created』——不是增量收敛？" >&2; exit 1; }
    note "[ok] 只新增 gamma，alpha/beta 一行未动（明细见 $LOGS/scale-up.log）"
    [ "$(count_sites)" = "3" ] || { echo "    [!] 期望 3 个站点，实际 $(count_sites)" >&2; exit 1; }
    wait_http http://localhost:28093/; check_nginx 28093
    note "还原 2 站点版本，再 up（反向也只动差集）："
    mv program/.sites.ts.bak program/sites.ts
    run scale-down up --yes
    grep -q -- "- 1 deleted" "$LOGS/scale-down.log" \
        || { echo "    [!] 未观察到『- 1 deleted』" >&2; exit 1; }
    [ "$(count_sites)" = "2" ] || { echo "    [!] 期望还原为 2 个站点，实际 $(count_sites)" >&2; exit 1; }
    note "[ok] gamma 被删除，alpha/beta 依旧无事——期望态驱动的增量收敛"
}

do_fail() {
    step "fail" "部署前防线：端口类型写错的程序，能不能带病上岗？"
    cp program/index.ts program/.index.ts.bak
    cat > program/index.ts <<'EOF'
// index.ts —— fail 段自动生成的"带病版本"：external 写成了 site.name（string）
// （跑完自动还原为正确版本；正确版的完整内容见 program/index.ts 还原结果）
import * as pulumi from "@pulumi/pulumi";
import * as docker from "@pulumi/docker";
import { WEB_SITES, Site } from "./sites";

const appName = "pulumi02";
const net = new docker.Network("net", { name: `${appName}-net` });

function makeSite(site: Site): docker.Container {
    const image =
        site.channel === "preview" ? "nginx:1.25-alpine" : "nginx:1.27-alpine";
    return new docker.Container(`site-${site.name}`, {
        name: `${appName}-${site.name}`,
        image,
        ports: [{ internal: 80, external: site.name }],
        networksAdvanced: [{ name: net.name }],
    });
}

const containers: docker.Container[] = [];
for (const site of WEB_SITES) {
    containers.push(makeSite(site));
}

export const urls = WEB_SITES.map(
    (site) => `http://localhost:${site.port}/`,
);
EOF
    note "把 external（应为 number）写成字符串后再跑 tsc："
    if (cd program && npx tsc --noEmit --pretty false) >"$LOGS/tsc-fail.log" 2>&1; then
        mv program/.index.ts.bak program/index.ts
        echo "    [!] 类型错误竟然通过了编译" >&2; exit 1
    fi
    grep -q "TS2322" "$LOGS/tsc-fail.log" \
        || { mv program/.index.ts.bak program/index.ts; echo "    [!] 报的不是预期的 TS2322" >&2; exit 1; }
    note "[ok] 编译期拦截（exit≠0：部署根本没机会发生），原文："
    sed 's/^/        /' "$LOGS/tsc-fail.log"
    mv program/.index.ts.bak program/index.ts
    (cd program && npx tsc --noEmit) >/dev/null 2>&1 \
        || { echo "    [!] 还原后类型检查竟然不过" >&2; exit 1; }
    note "[ok] 已还原 index.ts，类型检查回绿"
}

do_clean() {
    step "clean" "destroy 全清 + 残留断言"
    if $PU stack select dev >/dev/null 2>&1; then
        run destroy destroy --yes
    else
        note "栈不存在（没跑过 apply），直接做残留清理"
    fi
    local leftover nets
    leftover=$(docker ps -a --format '{{.Names}}' | grep '^pulumi02' || true)
    nets=$(docker network ls --format '{{.Name}}' | grep '^pulumi02' || true)
    if [ -z "$leftover" ] && [ -z "$nets" ]; then
        note "[ok] 容器/网络零残留，回到实验前状态"
    else
        note "[!] 有残留：${leftover:-} ${nets:-}" >&2
        return 1
    fi
    rm -rf "$LOGS"
    note "日志已清；state 记账本 .pulumi-state/ 保留（destroy 后是空栈）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)   do_apply ;;
        observe) do_observe ;;
        scale)   do_scale ;;
        fail)    do_fail ;;
        clean)   do_clean ;;
        all)     do_apply; do_observe; do_scale; do_fail; do_clean ;;
        *) echo "可用: apply | observe | scale | fail | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
