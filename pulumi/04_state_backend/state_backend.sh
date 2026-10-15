#!/usr/bin/env bash
# =============================================================================
# 04 · 状态管理（本地 file → MinIO S3 后端）— 主演示脚本
#
# 完整生命周期：apply → migrate → drift → adopt → clean
# 用法：
#   ./state_backend.sh apply    # 本地 file 后端建栈 up，看 state 目录结构
#   ./state_backend.sh migrate  # 起 MinIO，账本整体搬家（export→import），零 diff 对账
#   ./state_backend.sh drift    # docker rm -f 制造漂移，refresh 检出 → up 自愈
#   ./state_backend.sh adopt    # 手工 docker run 的容器被 import 接管，destroy 全清
#   ./state_backend.sh clean    # 两后端销毁 + MinIO 下线，零残留
#   ./state_backend.sh          # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# Go 类客户端不认 docker context，显式选一个响应正常的 socket（见 scripts/docker-env.sh）
. "../../scripts/docker-env.sh"

# 本实验全程用 PULUMI_BACKEND_URL 选后端——等价于 pulumi login <url>，但只影响
# 本进程，不碰 ~/.pulumi 里的全局登录态（clean 后机器零痕迹）
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1
export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"     # apply 段用本地；migrate 段切 s3

# S3 后端凭据（MinIO 的 root 账号）：SDK 按 AWS_* 环境变量解析；
# 端点与 path-style 只能写进后端 URL 的查询参数——AWS_S3_FORCE_PATH_STYLE、
# AWS_ENDPOINT_URL 这类环境变量 Pulumi 的 s3 backend 不认（实测 InvalidBucketName）
export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY=minioadmin
export AWS_REGION=us-east-1
# MinIO 响应不带校验和——SDK 默认"能校就校"会刷 WARN，改为"必要才校"
export AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED
PU="pulumi -C program"
LOGS=".logs"
NET="pulumi04-net"
MINIO="pulumi04-minio"
BUCKET="pulumi04-state"
PORT=28301
STACK="dev"
# 端点与 path-style 写进后端 URL 查询参数（见上：环境变量 Pulumi 不认）
S3_URL="s3://${BUCKET}?endpoint=http://localhost:29000&s3ForcePathStyle=true"

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

# 镜像不存在则拉取：直连 → daocloud 回源 → minio 系再试官方 quay.io
# （与 scripts/load_resources.sh 同策略；mc 拉不到时由 create_bucket 走宿主 aws 兜底）
ensure_image() {
    local img="$1" fallback alt
    docker image inspect "$img" >/dev/null 2>&1 && return 0
    note "拉取镜像 $1（直连失败自动换 daocloud，minio 系再试 quay.io）"
    docker pull -q "$img" >/dev/null 2>&1 && return 0
    case "$img" in
        */*) fallback="docker.m.daocloud.io/$img" ;;
        *)   fallback="docker.m.daocloud.io/library/$img" ;;
    esac
    if docker pull -q "$fallback" >/dev/null 2>&1; then
        docker tag "$fallback" "$img" && docker rmi "$fallback" >/dev/null || true
        return 0
    fi
    case "$img" in
        minio/*)
            alt="quay.io/minio/${img#minio/}"
            if docker pull -q "$alt" >/dev/null 2>&1; then
                docker tag "$alt" "$img" && docker rmi "$alt" >/dev/null || true
                return 0
            fi
            ;;
    esac
    return 1
}

ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    if [ ! -d program/node_modules ]; then
        note "首次运行：安装 TS 依赖（npm install，约 1 分钟）"
        (cd program && npm install --loglevel=error)
    fi
    mkdir -p .pulumi-state
}

# 建桶：优先 mc 容器（labs/03 同款）；镜像拉不到时用宿主 aws CLI 兜底
# （MinIO 容器每次 ensure_minio 都重建，/data 全新，桶必为空——无需清残留）
create_bucket() {
    if docker image inspect minio/mc >/dev/null 2>&1; then
        docker run --rm --network "${NET}" minio/mc sh -c \
            "mc alias set m http://${MINIO}:9000 minioadmin minioadmin >/dev/null \
             && mc mb -p m/${BUCKET} >/dev/null"
    elif command -v aws >/dev/null 2>&1; then
        note "minio/mc 镜像不可用，改用宿主 aws CLI 建桶"
        aws --endpoint-url http://localhost:29000 s3api create-bucket --bucket "${BUCKET}" >/dev/null \
            || { echo "    [!] 建桶失败" >&2; exit 1; }
    else
        echo "    [!] 既无 minio/mc 镜像，宿主也无 aws CLI：无法建桶" >&2; exit 1
    fi
}

# 起 MinIO（S3 兼容对象存储）+ 建桶；即用即弃，账本随容器生死
ensure_minio() {
    ensure_image minio/minio
    ensure_image minio/mc || true
    docker network create "${NET}" >/dev/null 2>&1 || true
    docker rm -f "${MINIO}" >/dev/null 2>&1 || true
    docker run -d --name "${MINIO}" --network "${NET}" \
        -p 29000:9000 -p 29001:9001 \
        -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
        minio/minio server /data --console-address ":9001" >/dev/null
    local i=0
    until curl -fsS http://localhost:29000/minio/health/live >/dev/null 2>&1; do
        i=$((i+1)); [ "$i" -gt 30 ] && { echo "    [!] MinIO 30s 未就绪" >&2; exit 1; }
        sleep 1
    done
    create_bucket
}

# 幂等建栈：select 失败才 init（重跑不报错）
ensure_stack() {
    if ! $PU stack select "${STACK}" >/dev/null 2>&1; then
        $PU stack init "${STACK}" >/dev/null
        note "已创建栈 ${STACK}（当前后端：${PULUMI_BACKEND_URL}）"
    fi
    $PU config set port "${PORT}" --stack "${STACK}" >/dev/null
}

do_apply() {
    step "apply" "本地 file 后端：建栈、up、看账本长什么样"
    ensure_ready
    ensure_stack
    run up-local up --stack "${STACK}" --yes
    if grep -q "created" "$LOGS/up-local.log"; then
        note "[ok] 创建完成"
    elif grep -q "unchanged" "$LOGS/up-local.log"; then
        note "[ok] 已在期望态（零变更，重跑幂等）"
    else
        echo "    [!] up 结果异常，看 ${LOGS}/up-local.log" >&2; exit 1
    fi
    wait_http "http://localhost:${PORT}/"; check_nginx "${PORT}"
    note "[ok] 容器在跑，http://localhost:${PORT}/ 命中 nginx"
    note "本地 file 后端的目录结构（账本本体）："
    ( cd .pulumi-state && find . -type f | sort ) | sed 's/^/        /'
    grep -q "docker:index/container:Container" ".pulumi-state/.pulumi/stacks/pulumi04-state-backend/${STACK}.json" \
        || { echo "    [!] 栈文件里没找到容器资源" >&2; exit 1; }
    note "[ok] state 就是 JSON：栈文件里能 grep 到资源 URN——账本可读、可备份、可搬家"
}

do_migrate() {
    step "migrate" "账本搬家：本地 file → MinIO（S3 兼容）"
    ensure_minio
    note "导出本地账本（stack export，账本可序列化）："
    $PU stack export --stack "${STACK}" 2>&1 | tee "$LOGS/local-state.json" >/dev/null
    note "        $(wc -c <"$LOGS/local-state.json" | tr -d ' ') 字节 → .logs/local-state.json"
    export PULUMI_BACKEND_URL="${S3_URL}"
    note "切到 S3 后端，stack ls 应为空（新后端一本账都没有）："
    $PU stack ls 2>&1 | sed 's/^/        /'
    if $PU stack select "${STACK}" >/dev/null 2>&1; then
        echo "    [!] 新后端竟然已有栈 ${STACK}——上轮残留？跑 clean 后再试" >&2; exit 1
    fi
    $PU stack init "${STACK}" >/dev/null
    note "导入账本（stack import），再 up 对账："
    # --file 的相对路径相对 -C program 解析，必须给绝对路径
    $PU stack import --stack "${STACK}" --file "${PWD}/$LOGS/local-state.json" >/dev/null
    run up-after-migrate up --stack "${STACK}" --yes
    grep -qE "to create|to update|to delete|to replace" "$LOGS/up-after-migrate.log" \
        && { echo "    [!] 迁移后 up 出现变更——账本没搬对" >&2; exit 1; }
    grep -q "unchanged" "$LOGS/up-after-migrate.log" \
        || { echo "    [!] 未见 unchanged——对账结果异常" >&2; exit 1; }
    note "[ok] up 零 diff：程序、容器、现实都没动，只有账本换了存放地"
    note "S3 后端的账本就是桶里的一组对象（key 列表，前 10 条）："
    local keys
    if command -v aws >/dev/null 2>&1; then
        keys=$(aws --endpoint-url http://localhost:29000 s3api list-objects-v2 \
            --bucket "${BUCKET}" --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n')
    else
        keys=$(docker exec "${MINIO}" ls -R "/data/${BUCKET}" 2>/dev/null)
    fi
    head -10 <<<"$keys" | sed 's/^/        /'
    grep -q "stacks/pulumi04-state-backend/${STACK}.json" <<<"$keys" \
        || { echo "    [!] 桶里没找到栈 checkpoint 对象" >&2; exit 1; }
    note "[ok] 账本以对象形式落在桶里——key 与本地 file 后端的路径一一对应"
    note "本地旧账本仍在（迁移是复制不是移动）："
    ls .pulumi-state/.pulumi/stacks/pulumi04-state-backend/ | sed 's/^/        /'
}

do_drift() {
    step "drift" "漂移检出：账本说在，现实不在——refresh 对账"
    docker rm -f pulumi04-web >/dev/null
    note "手工删掉容器后，refresh 检出漂移："
    run refresh refresh --stack "${STACK}" --yes
    grep -q "deleted" "$LOGS/refresh.log" \
        || { echo "    [!] refresh 未检出容器被删" >&2; exit 1; }
    note "[ok] refresh 已把账本对齐现实（该资源从账本移除）"
    run up-heal up --stack "${STACK}" --yes
    grep -q "created" "$LOGS/up-heal.log" \
        || { echo "    [!] up 未重建容器" >&2; exit 1; }
    wait_http "http://localhost:${PORT}/"; check_nginx "${PORT}"
    note "[ok] up 按期望态重建，服务恢复——远端账本一样能自愈"
}

do_adopt() {
    step "adopt" "接管：手工 docker run 的容器收编进账本"
    docker rm -f pulumi04-stray >/dev/null 2>&1 || true
    docker run -d --name pulumi04-stray nginx:1.27-alpine >/dev/null
    note "pulumi04-stray 是纯手工创建的（账本里没有），import 收编："
    note "（import 第三参是资源真实 ID——容器 64 位长 ID；只给名字会报 not exist，实测）"
    local stray_id
    stray_id=$(docker inspect --format '{{.Id}}' pulumi04-stray)
    run import-stray import docker:index/container:Container stray "${stray_id}" \
        --protect=false --yes
    grep -q "pulumi04-stray" "$LOGS/import-stray.log" \
        || { echo "    [!] import 输出里未见 stray" >&2; exit 1; }
    $PU stack export --stack "${STACK}" 2>/dev/null | grep -q "pulumi04-stray" \
        || { echo "    [!] 接管后账本里没有 stray" >&2; exit 1; }
    note "[ok] stray 已进账本（--protect=false：接管即可销毁，教学用）"
    note "但程序 index.ts 里没有它——preview 直言下场："
    $PU preview --stack "${STACK}" 2>&1 | tee "$LOGS/preview-orphan.log" >/dev/null
    grep -q "to delete" "$LOGS/preview-orphan.log" \
        || { echo "    [!] preview 未见删除计划" >&2; exit 1; }
    note "        $(grep -B1 'to delete' "$LOGS/preview-orphan.log" | head -2 | sed 's/^/        /')"
    note "[ok] 期望态由程序定义：账本里有、程序里没有 → 下一次 up 就会删掉它"
    run destroy-all destroy --stack "${STACK}" --yes
    if docker ps -a --format '{{.Names}}' | grep -qE '^pulumi04-(web|stray)$'; then
        echo "    [!] 容器有残留" >&2; exit 1
    fi
    note "[ok] destroy 全清：托管的 web 与接管来的 stray 一起从现实和账本里消失"
}

do_clean() {
    step "clean" "两后端销毁 + MinIO 下线，零残留"
    local backend
    for backend in "${S3_URL}" "file://$PWD/.pulumi-state"; do
        export PULUMI_BACKEND_URL="$backend"
        if $PU stack select "${STACK}" >/dev/null 2>&1; then
            run "destroy-$( [ "${backend#s3://}" != "$backend" ] && echo s3 || echo local )" \
                destroy --stack "${STACK}" --yes || true
        fi
    done
    docker rm -f "${MINIO}" pulumi04-web pulumi04-stray >/dev/null 2>&1 || true
    docker network rm "${NET}" >/dev/null 2>&1 || true
    if docker ps -a --format '{{.Names}}' | grep -q '^pulumi04'; then
        echo "    [!] 有残留容器" >&2; exit 1
    fi
    note "[ok] 容器/网络/MinIO 零残留（s3 账本随 MinIO 容器消失——实验性后端）"
    rm -rf "$LOGS"
    note "日志已清；本地 .pulumi-state 与 Pulumi.yaml 保留（配置与账本是项目资产）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)   do_apply ;;
        migrate) do_migrate ;;
        drift)   do_drift ;;
        adopt)   do_adopt ;;
        clean)   do_clean ;;
        all)     do_apply; do_migrate; do_drift; do_adopt; do_clean ;;
        *) echo "可用: apply | migrate | drift | adopt | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
