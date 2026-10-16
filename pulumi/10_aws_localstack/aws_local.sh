#!/usr/bin/env bash
# =============================================================================
# 10 · AWS Provider（LocalStack）— 主演示脚本
#
# 完整生命周期：apply → update → clean
# 用法：
#   ./aws_local.sh apply    # LocalStack 探活/拉起 → up 建 bucket+对象 → awslocal 交叉验证
#   ./aws_local.sh update   # 改对象内容再 up：原地更新（bucket 不动）
#   ./aws_local.sh clean    # destroy 后 s3 ls 断言桶消失（LocalStack 保留运行）
#   ./aws_local.sh          # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1

# aws CLI 交叉验证：endpoint 指向 LocalStack + 假凭证
AWSLS=(aws --endpoint-url http://localhost:4566)
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true

PU="pulumi -C program"
LOGS=".logs"
BUCKET="pulumi10-demo"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

run() {
    local name="$1"; shift
    mkdir -p "$LOGS"
    $PU "$@" 2>&1 | tee "$LOGS/$name.log"
}

ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    command -v localstack >/dev/null || { echo "需要 LocalStack CLI：brew install localstack/tap/localstack" >&2; exit 1; }
    if [ ! -d program/node_modules ]; then
        note "首次运行：安装 TS 依赖（npm install，约 1 分钟）"
        (cd program && npm install --loglevel=error)
    fi
    # aws provider 插件很大（数百 MB），预装一次，重跑秒回
    if ! pulumi plugin ls 2>/dev/null | grep -q "aws.*resource.*7.50.0"; then
        note "预装 aws provider 插件 7.50.0（包大，首装约 2-3 分钟）"
        pulumi plugin install resource aws 7.50.0 2>&1 | tail -1 | sed 's/^/        /'
    fi
    mkdir -p .pulumi-state
}

ensure_localstack() {
    if curl -fsS http://localhost:4566/_localstack/health >/dev/null 2>&1; then
        note "LocalStack 已在运行"
    else
        note "拉起 LocalStack（docker 模式，需免费 token，本机已配置）"
        docker rm -f localstack-main >/dev/null 2>&1 || true
        localstack start -d 2>&1 | tail -1 | sed 's/^/        /'
        local i=0
        until curl -fsS http://localhost:4566/_localstack/health >/dev/null 2>&1; do
            i=$((i+1)); [ "$i" -gt 30 ] && { echo "    [!] LocalStack 60s 未就绪" >&2; exit 1; }
            sleep 2
        done
    fi
    local s3
    s3=$(curl -s http://localhost:4566/_localstack/health | python3 -c "import json,sys; print(json.load(sys.stdin).get('services',{}).get('s3','unknown'))")
    case "${s3}" in
        running|available) note "[ok] LocalStack 就绪，s3 服务 ${s3}" ;;
        *) echo "    [!] s3 服务不可用（${s3}）" >&2; exit 1 ;;
    esac
    note "[ok] LocalStack 就绪，s3 服务 ${s3}"
}

ensure_stack() {
    if ! $PU stack select dev >/dev/null 2>&1; then
        $PU stack init dev >/dev/null
        note "已创建栈 dev"
    fi
    $PU config set content "hello from pulumi v1" --stack dev >/dev/null
}

do_apply() {
    step "apply" "up 建 bucket + 对象，awslocal 交叉验证"
    ensure_ready
    ensure_localstack
    ensure_stack
    run up up --stack dev --yes
    if grep -q "created" "$LOGS/up.log"; then
        note "[ok] 创建完成"
    elif grep -q "unchanged" "$LOGS/up.log"; then
        note "[ok] 已在期望态（零变更，重跑幂等）"
    else
        echo "    [!] up 结果异常，看 ${LOGS}/up.log" >&2; exit 1
    fi
    note "aws s3 ls（经 LocalStack）："
    "${AWSLS[@]}" s3 ls | sed 's/^/        /'
    "${AWSLS[@]}" s3 ls "s3://$BUCKET" | grep -q "hello.txt" \
        || { echo "    [!] 桶里没有 hello.txt" >&2; exit 1; }
    note "交叉验证：本地写文件 → cp 进桶 → 拉回比对 → 删除桶内副本"
    echo "written by aws cli" > "$LOGS/by-aws-cli.txt"
    "${AWSLS[@]}" s3 cp "$LOGS/by-aws-cli.txt" "s3://$BUCKET/by-aws-cli.txt" >/dev/null
    "${AWSLS[@]}" s3 cp "s3://$BUCKET/by-aws-cli.txt" "$LOGS/by-aws-cli-back.txt" >/dev/null
    diff "$LOGS/by-aws-cli.txt" "$LOGS/by-aws-cli-back.txt" >/dev/null \
        || { echo "    [!] cp 往返内容不一致" >&2; exit 1; }
    "${AWSLS[@]}" s3 rm "s3://$BUCKET/by-aws-cli.txt" >/dev/null
    note "[ok] aws cli 对同一个桶读写自如——Pulumi 声明的就是真实 S3"
}

do_update() {
    step "update" "只改对象内容再 up：原地更新，bucket 不动"
    $PU config set content "hello from pulumi v2" --stack dev >/dev/null
    run up-update up --stack dev --yes
    if grep -q "updated" "$LOGS/up-update.log" && ! grep -qE "to replace|to create" "$LOGS/up-update.log"; then
        note "[ok] diff 只有对象内容的原地更新（bucket 无 replace）"
    else
        echo "    [!] 期望原地更新，实际 diff 见 ${LOGS}/up-update.log" >&2; exit 1
    fi
    local body
    body=$("${AWSLS[@]}" s3 cp "s3://$BUCKET/hello.txt" - 2>/dev/null)
    grep -q "v2" <<<"$body" || { echo "    [!] 桶内对象未更新为 v2" >&2; exit 1; }
    note "[ok] 桶内 hello.txt 已是 v2——一次 up，云端内容跟着配置走"
}

do_clean() {
    step "clean" "destroy 后断言桶消失（LocalStack 保留运行）"
    if $PU stack select dev >/dev/null 2>&1; then
        run destroy destroy --stack dev --yes
    fi
    if "${AWSLS[@]}" s3 ls 2>/dev/null | grep -q "$BUCKET"; then
        echo "    [!] 桶 $BUCKET 仍存在" >&2; exit 1
    fi
    note "[ok] 桶与对象已从 LocalStack 删除，零残留"
    note "LocalStack 保留运行（可复用）；停止：localstack stop"
    rm -rf "$LOGS"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)  do_apply ;;
        update) do_update ;;
        clean)  do_clean ;;
        all)    do_apply; do_update; do_clean ;;
        *) echo "可用: apply | update | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
