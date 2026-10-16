#!/usr/bin/env bash
# =============================================================================
# 09 · Kubernetes Provider（kind 部署应用）— 主演示脚本
#
# 完整生命周期：apply → rollout → clean
# 用法：
#   ./k8s_kind.sh apply     # 专用 kind 集群上 up：Namespace + Deployment + Service
#   ./k8s_kind.sh rollout   # 换镜像 tag 再 up：kubectl rollout status 通过
#   ./k8s_kind.sh clean     # destroy 后 kubectl get all 零残留（集群保留）
#   ./k8s_kind.sh           # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1

PU="pulumi -C program"
LOGS=".logs"
CLUSTER="pulumi-lab"
NODE_IMAGE="kindest/node:v1.36.1"    # pin 本地已有镜像，网络不好也能建集群
NS="pulumi09-lab"
CTX="kind-$CLUSTER"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

run() {
    local name="$1"; shift
    mkdir -p "$LOGS"
    $PU "$@" 2>&1 | tee "$LOGS/$name.log"
}

kc() { kubectl --context "$CTX" "$@"; }

ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    command -v kind >/dev/null || { echo "需要 kind：brew install kind" >&2; exit 1; }
    command -v kubectl >/dev/null || { echo "需要 kubectl：brew install kubectl" >&2; exit 1; }
    if [ ! -d program/node_modules ]; then
        note "首次运行：安装 TS 依赖（npm install，约 1 分钟）"
        (cd program && npm install --loglevel=error)
    fi
    mkdir -p .pulumi-state
}

# 专用集群：与机器上其他 kind 集群隔离；已存在则复用（幂等）
ensure_cluster() {
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
        note "专用集群 $CLUSTER 已存在，直接复用"
    else
        note "创建专用 kind 集群 $CLUSTER（--image pin 本地镜像，约 1 分钟）"
        kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" 2>&1 | tail -2 | sed 's/^/        /'
    fi
    # kind 节点的 containerd 不共享宿主镜像：把实验用的两个 tag 提前装进去
    # （默认 imagePullPolicy=IfNotPresent，节点里有就不会去碰 docker.io）。
    # kind load docker-image 在 OrbStack 导出的多架构 tar 上会报
    # `ctr: content digest ... not found`，所以直接 docker save | ctr import。
    for img in nginx:1.27-alpine nginx:1.25-alpine; do
        docker image inspect "$img" >/dev/null 2>&1 || {
            note "宿主缺 $img，从 daocloud 回源拉取"
            docker pull -q "docker.m.daocloud.io/library/$img" >/dev/null \
                && docker tag "docker.m.daocloud.io/library/$img" "$img" \
                && docker rmi "docker.m.daocloud.io/library/$img" >/dev/null
        }
        local repo="${img%%:*}" tag="${img##*:}"
        if ! docker exec "$CLUSTER-control-plane" crictl img 2>/dev/null \
            | grep "docker.io/library/$repo" | grep -q "$tag"; then
            docker save "$img" \
                | docker exec -i "$CLUSTER-control-plane" ctr --namespace=k8s.io images import - \
                >/dev/null 2>&1
        fi
        docker exec "$CLUSTER-control-plane" crictl img 2>/dev/null \
            | grep "docker.io/library/$repo" | grep -q "$tag" \
            || { echo "    [!] $img 未进 kind 节点" >&2; exit 1; }
        note "[ok] 节点内已有 $img"
    done
    kc get nodes --no-headers | sed 's/^/        /'
}

ensure_stack() {
    if ! $PU stack select dev >/dev/null 2>&1; then
        $PU stack init dev >/dev/null
        note "已创建栈 dev"
    fi
    $PU config set imageTag 1.27 --stack dev >/dev/null
}

do_apply() {
    step "apply" "kind 集群上 up：Namespace + Deployment(2 副本) + Service"
    ensure_ready
    ensure_cluster
    ensure_stack
    run up up --stack dev --yes
    if grep -q "created" "$LOGS/up.log"; then
        note "[ok] 创建完成"
    elif grep -q "unchanged" "$LOGS/up.log"; then
        note "[ok] 已在期望态（零变更，重跑幂等）"
    else
        echo "    [!] up 结果异常，看 ${LOGS}/up.log" >&2; exit 1
    fi
    note "kubectl 视角验收（deploy + svc）："
    kc get deploy,svc -n "$NS" | sed 's/^/        /'
    local ready
    ready=$(kc get deploy web -n "$NS" -o jsonpath='{.status.readyReplicas}')
    [ "$ready" = "2" ] || { echo "    [!] readyReplicas=$ready，期望 2" >&2; exit 1; }
    local img
    img=$(kc get deploy web -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
    [ "$img" = "nginx:1.27-alpine" ] || { echo "    [!] 镜像不对：$img" >&2; exit 1; }
    note "[ok] web 就绪 2/2 副本，镜像 nginx:1.27-alpine"
}

do_rollout() {
    step "rollout" "换镜像 tag（1.27 → 1.25）再 up：滚动升级"
    $PU config set imageTag 1.25 --stack dev >/dev/null
    run up-rollout up --stack dev --yes
    grep -qE "updated|replaced|created" "$LOGS/up-rollout.log" \
        || { echo "    [!] up 未见变更" >&2; exit 1; }
    note "kubectl rollout status："
    kc rollout status deployment/web -n "$NS" --timeout=120s | sed 's/^/        /'
    local img
    img=$(kc get deploy web -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
    [ "$img" = "nginx:1.25-alpine" ] \
        || { echo "    [!] 滚动后镜像不对：$img" >&2; exit 1; }
    note "[ok] 滚动完成，镜像已到 nginx:1.25-alpine"
    $PU config set imageTag 1.27 --stack dev >/dev/null
    note "配置已还原 imageTag=1.27"
}

do_clean() {
    step "clean" "destroy 后 kubectl get all 零残留"
    if $PU stack select dev >/dev/null 2>&1; then
        run destroy destroy --stack dev --yes
    fi
    if kc get namespace "$NS" >/dev/null 2>&1; then
        echo "    [!] 命名空间 $NS 仍存在" >&2; exit 1
    fi
    note "[ok] 命名空间 $NS 已随栈删除，集群内零残留"
    note "kind 集群 $CLUSTER 保留（可重复实验）；彻底删除：kind delete cluster --name $CLUSTER"
    rm -rf "$LOGS"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)   do_apply ;;
        rollout) do_rollout ;;
        clean)   do_clean ;;
        all)     do_apply; do_rollout; do_clean ;;
        *) echo "可用: apply | rollout | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
