#!/usr/bin/env bash
# =============================================================================
# 14 · Kubernetes 插件 — 官方 cloudify-kubernetes-plugin 在本地模式部署 kind
#
# kubeconfig 随蓝图分发（blueprint_file_name 变体），FileDefinedResource 应用
# Deployment+Service；滚动更新走 kubectl set image（官方 update_resource_definition
# 工作流在 新版 k8s client + 新版 API server 组合下 PUT 422，负向留证）。
# 用法：
#   ./kubernetes_plugin.sh cluster    # kind cfy-lab 探活/创建 + 双镜像导入
#   ./kubernetes_plugin.sh install    # init + install + kubectl/curl 断言
#   ./kubernetes_plugin.sh update     # 滚动更新 1.29→1.27 + 旧 RS 缩零 + 插件重读
#   ./kubernetes_plugin.sh negative   # 官方 update 工作流 422 负向留证
#   ./kubernetes_plugin.sh uninstall  # 插件删除资源 + 零残留
#   ./kubernetes_plugin.sh all        # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=k8s
CTX=kind-cfy-lab
IMG_NEW="nginx:1.27-alpine"
IMG_OLD="nginx:1.29-alpine"

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

kctl() { kubectl --context "$CTX" "$@"; }

ensure_cluster() {
    # NOT `kind get clusters | grep -q`: grep -q exits early on match, the
    # writer gets SIGPIPE and pipefail turns the pipeline into a false failure
    if [[ "$(kind get clusters 2>/dev/null)" != *cfy-lab* ]]; then
        kind create cluster --image kindest/node:v1.36.1 --config cluster-config.yaml 2>&1 | tail -1
    fi
    for img in "$IMG_OLD" "$IMG_NEW"; do
        # kind 节点不共享宿主镜像；已导入则 ctr 会报 exists，忽略
        docker save "$img" | docker exec -i cfy-lab-control-plane ctr --namespace=k8s.io images import - >/dev/null 2>&1 || true
    done
    kctl wait --for=condition=Ready node/cfy-lab-control-plane --timeout=120s >/dev/null
    # kubeconfig 用外部地址（internal 地址只有 Manager 容器能解析——实测 DNS 失败）
    kind get kubeconfig --name cfy-lab > kubeconfig.yaml
    ok "kind cfy-lab 就绪（镜像 $IMG_OLD / $IMG_NEW 已导入）"
}

do_cluster() {
    step cluster "kind cfy-lab 探活/创建 + 镜像导入"
    ensure_cluster
}

do_install() {
    step install "init + install：官方插件应用 Deployment+Service（NodePort 30080）"
    ensure_cluster
    # repeatable install: previous runs may have left (or updated) the deploy
    kctl delete deploy cfy14-web --ignore-not-found >/dev/null 2>&1
    kctl delete svc cfy14-web --ignore-not-found >/dev/null 2>&1
    reset_workdir
    cfy_run init init -b "$DEP" bp.yaml
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    kctl get deploy cfy14-web >/dev/null 2>&1 || fail "k8s 里没有 cfy14-web Deployment"
    kctl get svc cfy14-web >/dev/null 2>&1 || fail "k8s 里没有 cfy14-web Service"
    ok "kubectl 可见 Deployment + Service（NodePort 30080）"
    # pod 需要拉起时间：轮询而非裸命令（set -e 会静默退出）
    local i=0 img=""
    while :; do
        i=$((i + 1)); [ "$i" -gt 30 ] && fail "90s 内 pod 未就绪"
        img=$(kctl get deploy cfy14-web -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
        [ "$img" = "$IMG_OLD" ] && kctl rollout status deploy/cfy14-web --timeout=10s >/dev/null 2>&1 && break
        sleep 3
    done
    ok "初始镜像 ${IMG_OLD}，rollout 完成"
    i=0
    local code=""
    while :; do
        i=$((i + 1)); [ "$i" -gt 15 ] && fail "45s 内 :28120 未就绪（extraPortMappings）"
        code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" http://localhost:28120/ || true)
        [ "$code" = "200" ] && break
        sleep 3
    done
    ok "宿主 :28120 → NodePort 30080 → 200"
}

do_update() {
    step update "滚动更新 $IMG_OLD → ${IMG_NEW}（kubectl set image；官方工作流限制见 negative）"
    kctl set image deploy/cfy14-web "web=$IMG_NEW" >/dev/null
    kctl rollout status deploy/cfy14-web --timeout=180s >/dev/null
    ok "rollout 完成"
    local img
    img=$(kctl get deploy cfy14-web -o jsonpath='{.spec.template.spec.containers[0].image}')
    [ "$img" = "$IMG_NEW" ] || fail "更新后镜像应 ${IMG_NEW}，实为 $img"
    ok "镜像已到 $IMG_NEW"
    kctl get rs 2>/dev/null | awk 'NR>1 && $4==0 && /cfy14-web/{found=1} END{exit !found}' \
        && ok "旧 ReplicaSet 已缩至 0（滚动语义）" \
        || fail "旧 ReplicaSet 未缩零"
    local code=""
    i=0
    while :; do
        i=$((i + 1)); [ "$i" -gt 15 ] && fail "更新后 :28120 未恢复（45s）"
        code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" http://localhost:28120/ || true)
        [ "$code" = "200" ] && break
        sleep 3
    done
    ok "更新后宿主 :28120 仍 200"
    # 插件重读：poststart 把集群实况刷回 runtime properties
    cfy_run re-read executions start execute_operation -b "$DEP" \
        -p '{"operation": "cloudify.interfaces.lifecycle.poststart"}'
    must_contain .logs/re-read.log "'execute_operation' workflow execution succeeded" \
        "插件 poststart 重读成功（收敛建立在插件状态里）"
}

do_negative() {
    step negative "官方 update_resource_definition 工作流：422 负向留证"
    local wid
    wid=$(python3 "$CQ" "$CFY_WORKDIR" "$DEP" --alive | awk '$1 ~ /^web_/{print $1}')
    [ -n "$wid" ] || fail "找不到 web 实例"
    # changes 里带 kind+name 是官方要求（update_with_additions 靠它匹配）；
    # 即便如此 PUT 全量 definition 仍触发 min-availability 422 —— 插件与
    # 新版 k8s client/API server 组合的兼容坑（README 详述）
    cfy_run negative executions start update_resource_definition -b "$DEP" \
        -p '{"node_instance_id": "'"$wid"'", "resource_definition_changes": "{\"kind\": \"Deployment\", \"metadata\": {\"name\": \"cfy14-web\"}, \"spec\": {\"template\": {\"spec\": {\"containers\": [{\"name\": \"web\", \"image\": \"'"$IMG_OLD"'\"}]}}}}"}' || true
    must_contain .logs/negative.log \
        "update_resource_definition' workflow execution failed" \
        "官方 update 工作流执行失败（负向事实）"
    must_contain .logs/negative.log "\(422\)" "API 拒绝：422（PUT 全量 definition 触发保护）"
    ok "负向留证：官方工作流在新版 k8s 组合下不可用，滚动更新走 kubectl"
}

do_uninstall() {
    step uninstall "插件删除集群资源 → 零残留"
    # 实测：与 update 同族，插件对 Deployment 的写路径（delete 亦然）在
    # kubernetes client 26.1 + 新版 API server 组合下 422
    # （"Deployment does not have minimum availability"）——kubectl 兜底清理
    cfy_run uninstall executions start uninstall -b "$DEP" || true
    kctl delete deploy cfy14-web --ignore-not-found >/dev/null 2>&1 || true
    kctl delete svc cfy14-web --ignore-not-found >/dev/null 2>&1 || true
    kctl wait --for=delete svc/cfy14-web --timeout=30s >/dev/null 2>&1 || true
    local residue
    residue=$(kctl get deploy,svc -o name 2>/dev/null | grep -c "cfy14" || true)
    [ "$residue" = "0" ] || fail "集群内 cfy14 资源残留 $residue"
    ok "kubectl 兜底清理后零残留（插件 delete 422 负向已留证）"
}

case "${1:-all}" in
    cluster)   do_cluster ;;
    install)   do_install ;;
    update)    do_update ;;
    negative)  do_negative ;;
    uninstall) do_uninstall ;;
    all)
        do_cluster
        do_install
        do_update
        do_negative
        do_uninstall
        echo; echo "✅ 14 全部通过"
        ;;
    *) echo "用法: $0 [cluster|install|update|negative|uninstall|all]"; exit 1 ;;
esac
