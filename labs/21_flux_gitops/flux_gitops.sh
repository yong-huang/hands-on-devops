#!/usr/bin/env bash
# =============================================================================
# 21 · Flux GitOps — 主演示脚本（真调谐回路，全本地）
#
# GitOps 主链路：clusters/lab/ 声明 → push 到靶场 Gitea → GitRepository 拉取 →
# Kustomization 调谐。git push 即部署；手动改集群 → Flux 自动回正。
#
# ./flux_gitops.sh apply    集群/Flux/Gitea 就绪 + 建 GitRepository/Kustomization + 首次同步
# ./flux_gitops.sh observe  Flux 组件/CRD/源与调谐状态
# ./flux_gitops.sh push     改声明（副本 1→2）→ git push → Flux 自动跟上
# ./flux_gitops.sh drift    手动 scale → Flux 自动回正（GitOps 自愈）
# ./flux_gitops.sh clean    卸载 Flux + 清 demo（集群与 Gitea 仓库保留）
# ./flux_gitops.sh all      apply → observe → push → drift → clean（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

CTX="kind-flux-lab"
FLUX_NS="flux-system"
CLUSTER=flux-lab
GITEA="http://localhost:3300"
GIT_USER=devops
GIT_PASS=devops123
REPO_NAME=gitops
REPO_URL_HOST="http://localhost:3300/${GIT_USER}/${REPO_NAME}.git"   # 宿主 push 用
WORK=tmp/repo                                                        # 仓库工作副本（tmp/ 已 gitignore）
DECL=clusters/lab                                                    # 声明源（入 git）
POLL=90                                                              # 调谐等待上限（秒）

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

kctx() { kubectl --context "$CTX" "$@"; }
fctx() { flux --context "$CTX" "$@" 2>&1; }

wait_for() {  # wait_for <秒> <描述> <shell 字符串>
    # 在当前 shell eval：断言里用到的 kctx/fctx 是函数，bash -c 子进程不继承
    local n=0 desc="$2" cmd="$3"
    while :; do
        n=$((n + 1)); [ "$n" -gt "$((POLL / 3))" ] && fail "${desc}（${POLL}s 未达成）"
        eval "$cmd" >/dev/null 2>&1 && return 0
        sleep 3
    done
}

# -----------------------------------------------------------------------------
# 环境：kind 集群 + Flux 控制器（含本网络 ghcr 拉取自救）+ 靶场 Gitea
# -----------------------------------------------------------------------------
ensure_cluster() {
    if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER}$"; then
        # NOTE: 不要写 `kind get clusters | grep -q`——SIGPIPE 假失败（exp14 踩过）
        kind create cluster --name "$CLUSTER" --image kindest/node:v1.36.1 2>&1 | tail -1
    fi
    kctx wait --for=condition=Ready node/"${CLUSTER}-control-plane" --timeout=120s >/dev/null
    note "kind ${CLUSTER} Ready"
}

ensure_flux_images() {
    # 本网络对 ghcr.io 的层下载会无限爬行：容器侧拉取任务挂死且永不超时。
    # 自救链（全部实测）：NJU ghcr 镜像预拉（502 瞬时，重试即可）→ 重打 ghcr.io tag
    # → docker save | ctr 导入节点（kind load 在 OrbStack 必踩 digest not found）
    # → 重启 containerd 杀掉挂死的在途拉取 → IfNotPresent 命中本地镜像。
    local running
    running=$(kctx -n "$FLUX_NS" get pods --no-headers 2>/dev/null | grep -c Running || true)
    [ "${running:-0}" -ge 4 ] && { note "Flux 控制器已在跑（${running}/4）"; return 0; }

    step "apply" "安装 Flux（flux install）"
    flux install --context "$CTX" >/dev/null 2>&1 >/dev/null 2>&1 || true

    running=$(kctx -n "$FLUX_NS" get pods --no-headers 2>/dev/null | grep -c Running || true)
    [ "${running:-0}" -ge 4 ] && { note "Flux 控制器就绪（${running}/4）"; return 0; }

    note "ghcr 层拉取在本地网络会挂死——走 NJU 镜像预拉 + 节点导入的自救链"
    local imgs=("source-controller:v1.9.5" "kustomize-controller:v1.9.5" "notification-controller:v1.9.4" "helm-controller:v1.6.4")
    local img try
    for img in "${imgs[@]}"; do
        docker image inspect "ghcr.io/fluxcd/$img" >/dev/null 2>&1 && continue
        for try in 1 2 3; do
            docker pull -q "ghcr.nju.edu.cn/fluxcd/$img" >/dev/null 2>&1 && break
            [ "$try" = 3 ] && fail "NJU 镜像三次拉取失败：$img"
            note "  NJU 502（瞬时），重试 $try/3…"; sleep 3
        done
        docker tag "ghcr.nju.edu.cn/fluxcd/$img" "ghcr.io/fluxcd/$img"
    done
    for img in "${imgs[@]}"; do
        docker save "ghcr.io/fluxcd/$img" \
            | docker exec -i "${CLUSTER}-control-plane" ctr --namespace=k8s.io images import - >/dev/null 2>&1 \
            || fail "镜像导入节点失败：$img"
    done
    kctx -n "$FLUX_NS" delete pods --all --force --grace-period=0 >/dev/null 2>&1 || true
    docker exec "${CLUSTER}-control-plane" systemctl restart containerd >/dev/null 2>&1
    sleep 20
    # 首次 install 可能因镜像拉取挂起而失败（uninstall 后连 ns 都没建）——
    # 镜像就位后必须重跑一次 install，节点本地镜像秒起
    note "镜像已入节点，重新 install（本地镜像秒起）"
    flux install --context "$CTX" >/dev/null 2>&1 >/dev/null 2>&1 || true
    wait_for 90 "Flux 控制器 Running" \
        "[ \$(kctx -n \$FLUX_NS get pods --no-headers 2>/dev/null | grep -c Running) -ge 4 ]"
    note "Flux 控制器 4/4 Running（自救链走完）"
}

ensure_node_image() {  # 节点拉 docker.io 会爬行——demo 镜像由宿主导入（幂等）
    local img="$1"
    docker exec "${CLUSTER}-control-plane" crictl image 2>/dev/null | grep -q "$img" && return 0
    docker save "$img"         | docker exec -i "${CLUSTER}-control-plane" ctr --namespace=k8s.io images import - >/dev/null 2>&1         || fail "demo 镜像导入节点失败：$img"
    note "节点镜像就绪：$img"
}

ensure_gitea() {
    local st
    st=$(docker inspect -f '{{.State.Running}}' lab-gitea 2>/dev/null || echo missing)
    [ "$st" = "true" ] || docker start lab-gitea >/dev/null 2>&1
    wait_for 40 "靶场 Gitea 健康" "curl -s -m 4 $GITEA/api/healthz"
    # 幂等建仓：已存在（409）视为成功
    local rc=0
    curl -s -u "$GIT_USER:$GIT_PASS" -X POST "$GITEA/api/v1/user/repos" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$REPO_NAME\",\"private\":false,\"auto_init\":false}" >/dev/null || rc=$?
    note "Gitea 仓库 ${GIT_USER}/${REPO_NAME} 就绪（新建或已存在）"
}

seed_repo() {  # seed_repo → 把 clusters/ 目录树推上 Gitea（仓库布局=集群布局）
    mkdir -p "$(dirname "$WORK")"
    if [ -d "$WORK/.git" ]; then
        rm -rf "$WORK/clusters"
        cp -R clusters "$WORK/clusters"
        ( cd "$WORK" && git add -A && git -c user.name=lab -c user.email=lab@local \
            commit -qm "decl: $(date +%H%M%S)" && git push -q origin master ) \
            || ( cd "$WORK" && git push -q origin master )
    else
        rm -rf "$WORK"
        mkdir -p "$WORK"
        cp -R clusters "$WORK/clusters"
        ( cd "$WORK" \
            && git init -q -b master \
            && git add -A \
            && git -c user.name=lab -c user.email=lab@local commit -qm "decl: initial" \
            && git remote add origin "$REPO_URL_HOST" \
            && git push -qf "http://${GIT_USER}:${GIT_PASS}@localhost:3300/${GIT_USER}/${REPO_NAME}.git" master )
    fi
    note "声明已 push：$(cd "$WORK" && find . -name '*.yaml' -not -path './.git/*' | tr '\n' ' ')"
}

gwc() {  # kind 网桥的 IPv4 网关（pod 内经它访问宿主端口：Gitea 3300）
    # 必须显式取 Family 4：OrbStack 的 kind 网络是 v6 优先，裸 IPv6 塞进
    # GitRepository url 会被 go-git 判 invalid port（实测）
    docker network inspect kind         | python3 -c "import sys,json; c=json.load(sys.stdin)[0]['IPAM']['Config']; print([x['Gateway'] for x in c if ':' not in x['Gateway']][0])"
}

# -----------------------------------------------------------------------------
# 阶段
# -----------------------------------------------------------------------------
do_apply() {
    ensure_cluster
    ensure_gitea

    step "apply" "安装 Flux 控制器"
    ensure_flux_images
    ensure_node_image python:3.12-slim

    step "apply" "声明 push 到靶场 Gitea"
    seed_repo

    step "apply" "GitRepository + Kustomization（声明 Git 源与调谐目标）"
    local gw
    gw=$(gwc)
    kctx apply -f - <<YAML
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: lab
  namespace: $FLUX_NS
spec:
  interval: 15s
  url: http://${gw}:3300/${GIT_USER}/${REPO_NAME}.git
  ref: { branch: master }
  secretRef: { name: git-auth }
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: lab
  namespace: $FLUX_NS
spec:
  interval: 15s
  sourceRef: { kind: GitRepository, name: lab }
  path: ./clusters/lab
  prune: true
  wait: true
YAML
    kctx create secret generic git-auth -n "$FLUX_NS" \
        --from-literal=username="$GIT_USER" --from-literal=password="$GIT_PASS" \
        --dry-run=client -o yaml | kctx apply -f -

    step "apply" "等 Flux 首次同步（source Ready → kustomization Applied）"
    # 断言直读 condition（flux get 表格的 READY 列是 True/False，grep 'Ready' 永不命中）
    # jsonpath 过滤器的引号易与外层冲突——单引号字面量 + eval 期转义 + grep 收口
    wait_for "$POLL" "GitRepository Ready" \
        'kctx -n flux-system get gitrepository lab -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -qx True'
    wait_for "$POLL" "Kustomization Ready" \
        'kctx -n flux-system get kustomization lab -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -qx True' 
    fctx get kustomizations lab -n "$FLUX_NS" | sed 's/^/        /'

    step "apply" "demo 应用经 Flux 落地"
    wait_for "$POLL" "demo Deployment Available" \
        bash -c "kctx -n demo get deploy demo-app -o jsonpath='{.status.conditions[*].type}' | grep -q Available"
    kctx -n demo get deploy,svc --no-headers 2>/dev/null | sed 's/^/        /'
    note "[ok] 集群态 = git 态：${DECL} → Gitea → Flux 调谐（interval 15s）"
}

do_observe() {
    step "observe" "Flux 控制器"
    kctx -n "$FLUX_NS" get pods --no-headers 2>/dev/null | sed 's/^/        /'
    step "observe" "Flux CRD"
    note "toolkit CRD 数：$(kctx get crd 2>/dev/null | grep -c 'toolkit.fluxcd.io')"
    step "observe" "源与调谐"
    fctx get sources git -A 2>/dev/null | sed 's/^/        /'
    fctx get kustomizations -A 2>/dev/null | sed 's/^/        /'
}

do_push() {
    step "push" "改声明（副本 1→2）→ git push → Flux 自动跟上"
    local cur
    cur=$(kctx -n demo get deploy demo-app -o jsonpath='{.spec.replicas}')
    local want=$(( cur + 1 ))
    sed -i '' "s/replicas: ${cur}/replicas: ${want}/" "$WORK/clusters/lab/demo.yaml"
    cp "$WORK/clusters/lab/demo.yaml" "$DECL/demo.yaml"   # 反向同步声明源，保持两侧一致
    ( cd "$WORK" && git add -A && git -c user.name=lab -c user.email=lab@local \
        commit -qm "decl: replicas ${cur} -> ${want}" && git push -q origin master )
    note "push 完成，等待 Flux 调谐到 ${want} 副本…"
    wait_for "$POLL" "Deployment 副本=${want}（Flux 拉齐 git）" \
        "[ \$(kctx -n demo get deploy demo-app -o jsonpath='{.status.readyReplicas}') = ${want} ]"
    note "[ok] git push → Flux 自动部署：副本已达 ${want}（无需 kubectl apply）"
}

do_drift() {
    step "drift" "手动 scale（模拟有人绕过 git 改集群）→ Flux 自动回正"
    local declared
    declared=$(kctx -n demo get deploy demo-app -o jsonpath='{.spec.replicas}')
    kctx -n demo scale deploy demo-app --replicas=$(( declared + 3 ))
    note "已手动扩到 $(( declared + 3 ))，声明态仍是 ${declared}——等 Flux 回正…"
    wait_for "$POLL" "漂移被回正（副本回到 ${declared}）" \
        "[ \$(kctx -n demo get deploy demo-app -o jsonpath='{.status.readyReplicas}') = ${declared} ]"
    note "[ok] GitOps 自愈：实际态被拉回声明态 ${declared}（Kustomization revert）"
}

do_clean() {
    step "clean" "卸载 Flux + 清 demo"
    flux uninstall --context "$CTX" --silent >/dev/null 2>&1 || true
    kubectl --context "$CTX" delete namespace demo --ignore-not-found >/dev/null 2>&1 || true
    note "[ok] Flux 已卸载（kind ${CLUSTER} 与 Gitea 仓库保留，重跑 apply 即恢复）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)   do_apply ;;
        observe) do_observe ;;
        push)    do_push ;;
        drift)   do_drift ;;
        clean)   do_clean ;;
        all)     do_apply; do_observe; do_push; do_drift; do_clean ;;
        *) echo "可用: apply | observe | push | drift | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
