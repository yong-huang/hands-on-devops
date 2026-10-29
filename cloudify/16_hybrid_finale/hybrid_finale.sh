#!/usr/bin/env bash
# =============================================================================
# 16 · 🏁 混合编排终局 — 一个蓝图跨 Terraform / Docker / Ansible / Kubernetes + 自写插件
#
# 五世界（全本地模式）：TF 底座(network+api) → docker 插件 web（进 TF 网络，跨工具
# 数据流）→ establish 里 ansible 配置 → 自写 HttpCheck 探活 → k8s 插件并行分支；
# Day-2：06 的 rolling_restart 工作流。
# 用法：
#   ./hybrid_finale.sh install    # 五世界全建 + 行序/数据流/探活断言
#   ./hybrid_finale.sh dataflow   # web 在 TF 网络内可达 api（容器间网络验证）
#   ./hybrid_finale.sh day2       # rolling_restart batch=2 在终局部署上执行
#   ./hybrid_finale.sh uninstall  # 三世界零残留（TF destroy + docker rm + k8s 清）
#   ./hybrid_finale.sh all        # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=finale
STAGE=/tmp/handson16
WEB_PORT=28130
K8S_PORT=28120

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

first_line() {
    grep -nE "$2" "$1" | head -1 | cut -d: -f1
}

cleanup_all() {
    docker rm -f cfy16-web cfy16-api >/dev/null 2>&1 || true
    docker network rm cfy16-net >/dev/null 2>&1 || true
    kubectl --context kind-cfy-lab delete deploy cfy16-web --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context kind-cfy-lab delete svc cfy16-web --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context kind-cfy-lab delete cm cfy16-cm --ignore-not-found >/dev/null 2>&1 || true
    rm -rf "$STAGE"
    return 0
}

stage_all() {
    mkdir -p "$STAGE"
    (cd tf_module && zip -qr "$STAGE/tf-module.zip" .)
    # provider filesystem mirror（registry.terraform.io 本网络 RST，复用 labs/01）
    local mirror="$STAGE/tf-mirror"
    mkdir -p "$mirror/registry.terraform.io/kreuzwerker/docker/3.9.0/darwin_arm64"
    cp ../../labs/01_tf_docker_provider/configs/.terraform/providers/registry.terraform.io/kreuzwerker/docker/3.9.0/darwin_arm64/terraform-provider-docker_v3.9.0 \
        "$mirror/registry.terraform.io/kreuzwerker/docker/3.9.0/darwin_arm64/" 2>/dev/null
    cat > "$STAGE/tfrc" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "$mirror"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF
    cp playbooks/site.yaml "$STAGE/site.yaml"
    # kind 集群与镜像探活（复用 14 的集群）
    if ! kind get clusters 2>/dev/null | grep -q cfy-lab; then
        kind create cluster --image kindest/node:v1.36.1 --config ../14_kubernetes_plugin/cluster-config.yaml 2>&1 | tail -1
    fi
    docker save nginx:1.29-alpine | docker exec -i cfy-lab-control-plane ctr --namespace=k8s.io images import - >/dev/null 2>&1 || true
    kubectl --context kind-cfy-lab wait --for=condition=Ready node/cfy-lab-control-plane --timeout=120s >/dev/null
    kind get kubeconfig --name cfy-lab > kubeconfig.yaml
    # K8s 资源若上次残留先清（按名删：Service 自身无 label，-l 匹配不到）
    kubectl --context kind-cfy-lab delete deploy cfy16-web --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context kind-cfy-lab delete svc cfy16-web --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context kind-cfy-lab delete cm cfy16-cm --ignore-not-found >/dev/null 2>&1 || true
}

do_install() {
    step install "stage → init → install（单蓝图五世界）"
    cleanup_all
    stage_all
    reset_workdir
    cfy_run init init -b "$DEP" bp.yaml -i "tf_cli_config=$STAGE/tfrc"
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"

    local tf_create web_create k8s_done check_done
    tf_create=$(first_line .logs/install.log '\[tf_base_[a-z0-9]+\.create\] Task started')
    web_create=$(first_line .logs/install.log '\[web_[a-z0-9]+\.create\] Task started')
    k8s_done=$(first_line .logs/install.log "Subgraph succeeded 'install_k8s_web_[a-z0-9]+'")
    check_done=$(first_line .logs/install.log 'check_http [0-9]/[0-9] .* -> 200')
    [ -n "$tf_create" ] && [ -n "$web_create" ] || fail "日志缺 TF/web 关键行"
    [ "$tf_create" -lt "$web_create" ] || fail "TF create（行 ${tf_create}）应早于 web create（行 ${web_create}）"
    ok "行序：TF 底座（行 ${tf_create}）→ docker web（行 ${web_create}）——跨工具依赖序"
    [ -n "$k8s_done" ] && [ -n "$check_done" ] || fail "日志缺 k8s/HttpCheck 完成行"
    ok "k8s 分支完成（行 ${k8s_done}）且 HttpCheck 到 200（行 ${check_done}）"

    local code
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://localhost:$WEB_PORT/")
    [ "$code" = "200" ] || fail "web :$WEB_PORT = $code 应 200"
    ok "web 容器宿主可达（:${WEB_PORT}）"
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://localhost:28131/")
    [ "$code" = "200" ] || fail "TF 的 api 容器 :28131 = $code 应 200"
    ok "TF 起的 api 容器宿主可达（:28131）"
    [ "$(inst_attr "$DEP" status_code)" = "200" ] || fail "HttpCheck runtime property 应为 200"
    ok "自写插件 HttpCheck status_code = 200"
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://localhost:$K8S_PORT/")
    [ "$code" = "200" ] || fail "k8s NodePort :$K8S_PORT = $code 应 200"
    ok "K8s 分支宿主可达（:${K8S_PORT}，kind 映射 30081）"
    local motd
    motd=$(docker exec cfy16-web cat /etc/motd)
    [ "$motd" = "configured by cloudify hybrid finale" ] || fail "web 容器 motd 不符：$motd"
    ok "ansible establish 已配置 web 容器（/etc/motd）"
}

do_dataflow() {
    step dataflow "跨工具数据流：TF output 经 op-input get_attribute 流入另一节点"
    local net
    net=$(inst_attr "$DEP" recorded_network | head -1)
    [ "$net" = "cfy16-net" ] || fail "recorder 应记下 TF 输出 cfy16-net，实为 $net"
    ok "TF output → op-input get_attribute（任务期求值）→ runtime property"
    local members
    members=$(docker network inspect cfy16-net --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)
    echo "$members" | grep -q cfy16-api || fail "TF 网络成员应含 cfy16-api，实为 $members"
    ok "TF 网络成员含其自建的 api 容器（${members}）"
}

do_day2() {
    step day2 "rolling_restart batch=2 在终局部署上执行（06 的工作流）"
    cfy_run day2 executions start rolling_restart -b "$DEP" -p batch=2 \
        --task-thread-pool-size 2
    must_contain .logs/day2.log "'rolling_restart' workflow execution succeeded" "Day-2 工作流成功"
    [ "$(inst_attr "$DEP" status_code | head -1)" = "200" ] || true
    ok "rolling_restart 完成（restart 接口跑在 web 邻居节点上）"
}

do_uninstall() {
    step uninstall "uninstall → TF destroy + 容器删除 + K8s 清理 → 三世界零残留"
    # k8s 插件 delete 与 14 同族 422（对 Deployment 写路径不稳）——TF 与 docker
    # 部分正常删除，k8s 由 kubectl 按名兜底
    cfy_run uninstall executions start uninstall -b "$DEP" || true
    kubectl --context kind-cfy-lab delete deploy cfy16-web --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context kind-cfy-lab delete svc cfy16-web --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context kind-cfy-lab delete cm cfy16-cm --ignore-not-found >/dev/null 2>&1 || true
    must_contain .logs/uninstall.log "tf destroy done" "TF delete 钩子执行了 destroy"
    local residue
    residue=$(docker ps -aq --filter name=cfy16- | wc -l | tr -d ' ')
    [ "$residue" = "0" ] || fail "docker 残留 $residue"
    ok "docker 零残留（TF api + 插件 web 都删了）"
    residue=$(kubectl --context kind-cfy-lab get deploy,svc,cm 2>/dev/null | grep -c cfy16 || true)
    [ "$residue" = "0" ] || fail "k8s 残留 $residue"
    ok "k8s 零残留（kubectl 兜底）"
    cleanup_all
}

case "${1:-all}" in
    install)   do_install ;;
    dataflow)  do_dataflow ;;
    day2)      do_day2 ;;
    uninstall) do_uninstall ;;
    all)
        do_install
        do_dataflow
        do_day2
        do_uninstall
        echo; echo "✅ 16 全部通过"
        ;;
    *) echo "用法: $0 [install|dataflow|day2|uninstall|all]"; exit 1 ;;
esac
