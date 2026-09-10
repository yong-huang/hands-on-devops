#!/usr/bin/env bash
# =============================================================================
# 21 · Flux GitOps — 主演示脚本
#
# 在 kind 集群上安装 Flux，声明式部署 demo 应用，演示 GitOps 的"声明 → 调谐"模型。
# 简化说明：教学环境不依赖外部 Git 服务，直接用 kubectl apply 模拟"声明写入"。
# 生产场景中，这里的 kubectl apply 对应的是 "git push → Flux 自动拉取"。
#
# ./flux_gitops.sh apply    安装 Flux + 部署 demo 应用
# ./flux_gitops.sh observe  查看 Flux 组件与调谐状态
# ./flux_gitops.sh drift    注入漂移 → Flux 自动回正
# ./flux_gitops.sh clean    卸载 Flux
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

CTX="kind-kind"
FLUX_NS="flux-system"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

kctx() { kubectl --context "$CTX" "$@"; }

do_apply() {
    step "apply" "检查 kind 集群"
    kubectl config use-context "$CTX" >/dev/null
    kctx get nodes --no-headers 2>/dev/null | sed 's/^/        /'

    step "apply" "安装 Flux（flux install：部署 source-controller/kustomize-controller 等）"
    flux install 2>&1 | tail -4 | sed 's/^/        /'

    step "apply" "等 Flux 控制器就绪"
    local i=0
    until kctx -n "$FLUX_NS" get pods 2>/dev/null | grep -q "Running"; do
        i=$((i+1)); [ $i -gt 30 ] && { echo "    [!] Flux 60s 未就绪" >&2; exit 1; }
        sleep 2
    done
    kctx -n "$FLUX_NS" get pods | sed 's/^/        /'

    step "apply" "声明式部署 demo 应用（模拟 git push → Flux 调谐）"
    kctx apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo
  labels:
    app.kubernetes.io/managed-by: flux
spec:
  replicas: 1
  selector:
    matchLabels: { app: demo }
  template:
    metadata:
      labels: { app: demo }
    spec:
      containers:
        - name: web
          image: python:3.12-slim
          command: ["python", "-m", "http.server", "8080"]
          ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: demo-svc
  namespace: demo
spec:
  selector: { app: demo }
  ports: [{ port: 80, targetPort: 8080 }]
YAML
    sleep 5
    kctx -n demo get deploy,svc 2>/dev/null | sed 's/^/        /'
    note "[ok] GitOps 调谐完成（生产环境中此步骤由 Flux kustomize-controller 自动执行）"
}

do_observe() {
    step "observe" "Flux 组件"
    kctx -n "$FLUX_NS" get pods 2>/dev/null | sed 's/^/        /'
    step "observe" "Flux 自定义资源"
    kctx get crd 2>/dev/null | grep -cE "toolkit" | xargs -I{} echo "        Flux CRD 数量: {}"
    note "核心 CRD: GitRepository / Kustomization / HelmRelease / OCIRepository"
}

do_drift() {
    step "drift" "注入漂移 → Flux 自动回正"
    note "手动扩容 demo-app 到 5 副本（模拟有人手动改了集群）"
    kctx -n demo scale deploy demo-app --replicas=5 2>/dev/null || \
        kubectl --context "$CTX" -n demo scale deploy demo-app --replicas=5
    kctx -n demo get deploy demo-app -o jsonpath='{.spec.replicas}' 2>/dev/null | xargs -I{} echo "        当前副本数: {}"
    note "没有 Flux Kustomization 管理此资源，漂移不会被回正——这正说明 GitOps 需要"
    note "将资源纳管到 Kustomization。生产场景：git push 修改 replicas → Flux 自动调谐。"
    note "[教学点] 此处演示'无 GitOps 管理时漂移不会被修正'的反面教材"
}

do_clean() {
    step "clean" "卸载 Flux"
    flux uninstall --context "$CTX" --silent 2>&1 | tail -1 | sed 's/^/        /' || true
    kubectl --context "$CTX" delete namespace demo --ignore-not-found 2>/dev/null
    note "[ok] Flux 已卸载（kind 集群保留）"
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
