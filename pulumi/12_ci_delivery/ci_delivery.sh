#!/usr/bin/env bash
# =============================================================================
# 12 · 交付闭环（preview 门禁进 CI）— 主演示脚本
#
# 完整生命周期：gate → act → clean
# 用法：
#   ./ci_delivery.sh gate    # 本地验证两种门禁语义（--diff / --expect-no-changes）
#   ./ci_delivery.sh act     # act 本地跑三 job 链路：preview 门禁 → deploy → 漂移门禁
#   ./ci_delivery.sh clean   # 清两栈与资源桶（LocalStack 保留运行）
#   ./ci_delivery.sh         # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# 宿主与 CI 共用同一个 state 后端（LocalStack 的 S3，呼应实验 4 的自建后端）
export PULUMI_BACKEND_URL="s3://pulumi12-state?endpoint=http://localhost:4566&s3ForcePathStyle=true"
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true

AWSLS=(aws --endpoint-url http://localhost:4566)
PU="pulumi -C program"
LOGS=".logs"
ACT_HOME="$PWD/.act-cache/pulumi-home"    # 容器内 /root/.pulumi 的缓存卷（插件数百 MB）
IMG="catthehacker/ubuntu:act-latest"
BUCKET_PREFIX="pulumi12-app"
STATE_BUCKET="pulumi12-state"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

run() {
    local name="$1"; shift
    mkdir -p "$LOGS"
    $PU "$@" 2>&1 | tee "$LOGS/$name.log"
}

ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    command -v act >/dev/null || { echo "需要 act：brew install act" >&2; exit 1; }
    if [ ! -d program/node_modules ]; then
        note "首次运行：安装 TS 依赖（npm install，约 1 分钟）"
        (cd program && npm install --loglevel=error)
    fi
    if ! pulumi plugin ls 2>/dev/null | grep -q "aws.*resource.*7.50.0"; then
        note "预装 aws provider 插件 7.50.0（宿主侧；容器侧由 act 缓存卷负责）"
        pulumi plugin install resource aws 7.50.0 2>&1 | tail -1 | sed 's/^/        /'
    fi
    mkdir -p .pulumi-state "$ACT_HOME"
}

# state 后端与 LocalStack：探活、拉起、确保 state 桶存在
ensure_bases() {
    if curl -fsS http://localhost:4566/_localstack/health >/dev/null 2>&1; then
        note "[ok] LocalStack 复用（10/11 号实验所启）"
    else
        note "拉起 LocalStack"
        docker rm -f localstack-main >/dev/null 2>&1 || true
        localstack start -d 2>&1 | tail -1 | sed 's/^/        /'
        local i=0
        until curl -fsS http://localhost:4566/_localstack/health >/dev/null 2>&1; do
            i=$((i+1)); [ "$i" -gt 30 ] && { echo "    [!] LocalStack 60s 未就绪" >&2; exit 1; }
            sleep 2
        done
    fi
    "${AWSLS[@]}" s3api create-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1 || true
}

ensure_stack() {
    if ! $PU stack select dev >/dev/null 2>&1; then
        $PU stack init dev >/dev/null
        note "已创建栈 dev"
    fi
    $PU config set content "v1" --stack dev >/dev/null
}

do_gate() {
    step "gate" "本地验证两种门禁语义（先本地，再进 act）"
    ensure_ready
    ensure_bases
    ensure_stack
    run up-first up --stack dev --yes
    note "漂移门禁：无变更时 up --expect-no-changes 应退出 0"
    local rc=0
    $PU up --yes --expect-no-changes --stack dev > "$LOGS/expect-ok.log" 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || { echo "    [!] expect-no-changes 竟然失败（rc=$rc），看 ${LOGS}/expect-ok.log" >&2; exit 1; }
    note "[ok] 退出码 0：期望态无漂移"
    note "preview 门禁：改配置后 preview --diff 必须亮出变更条目"
    $PU config set content "v2" --stack dev >/dev/null
    $PU preview --diff --stack dev 2>&1 | tee "$LOGS/preview-diff.log" >/dev/null
    grep -qE "^[[:space:]]*[-+~].+=>" "$LOGS/preview-diff.log" \
        || { echo "    [!] preview --diff 未见变更条目" >&2; exit 1; }
    note "        $(grep -E "=> " "$LOGS/preview-diff.log" | head -2 | sed 's/^/        /')"
    $PU config set content "v1" --stack dev >/dev/null
    note "[ok] --diff 已亮出变更条目；配置还原 v1"
}

do_act() {
    step "act" "act 本地跑三 job 链路：preview 门禁 → deploy → 漂移门禁"
    ensure_ready
    ensure_bases
    local rc=0
    # flag 必须全在 act 根层级（0.2.89 的 push 子命令后解析不了这些 flag）；
    # --network 默认就是 host（容器内 localhost 直达宿主端口的 LocalStack）
    act \
        --bind \
        --pull=false \
        -P "ubuntu-latest=$IMG" \
        --action-offline-mode \
        --network host \
        --container-options "-v $ACT_HOME:/root/.pulumi" \
        -W ci/workflows/delivery.yml \
        2>&1 | tee "$LOGS/act.log" || rc=$?
    [ "$rc" -eq 0 ] || { echo "    [!] act 链路红（rc=${rc}），看 ${LOGS}/act.log" >&2; exit 1; }
    for job in preview-gate deploy drift-gate; do
        grep -qE "pulumi-delivery/$job[[:space:]]*\\].*Job succeeded" "$LOGS/act.log" \
            || { echo "    [!] 日志未见 $job 成功标志" >&2; exit 1; }
    done
    note "[ok] 三 job 全绿：preview 门禁 → deploy → 漂移门禁（CI 内 state 也走 LocalStack）"
}

do_clean() {
    step "clean" "清两栈与资源桶（LocalStack 保留运行）"
    if $PU stack select dev >/dev/null 2>&1; then
        run destroy-dev destroy --stack dev --yes
    fi
    if $PU stack select ci >/dev/null 2>&1; then
        # ci 栈是 workflow 用独立口令建的，清理时口令必须对上
        PULUMI_CONFIG_PASSPHRASE="ci-passphrase" run destroy-ci destroy --stack ci --yes
        PULUMI_CONFIG_PASSPHRASE="ci-passphrase" $PU stack rm ci --yes >/dev/null
    fi
    if "${AWSLS[@]}" s3 ls 2>/dev/null | grep -q "$BUCKET_PREFIX"; then
        echo "    [!] 资源桶（前缀 $BUCKET_PREFIX）仍存在" >&2; exit 1
    fi
    note "[ok] 资源桶与两栈已清；state 桶 $STATE_BUCKET 保留（后端资产）；LocalStack 保留运行"
    rm -rf "$LOGS"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        gate)  do_gate ;;
        act)   do_act ;;
        clean) do_clean ;;
        all)   do_gate; do_act; do_clean ;;
        *) echo "可用: gate | act | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
