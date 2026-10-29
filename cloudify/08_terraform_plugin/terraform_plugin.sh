#!/usr/bin/env bash
# =============================================================================
# 08 · Terraform 插件 — 「TF 模块当一个 TOSCA 节点」（script 包装主线 + 官方插件负向）
#
# 主线：script 插件包装本机 terraform（apply/destroy/漂移检出三操作），TF outputs
#       流回 runtime properties。官方 cloudify-terraform-plugin 在本地模式有
#       Manager 硬依赖（实测两条），保留 bp_official.yaml 作负向证据。
# 用法：
#   ./terraform_plugin.sh official-neg  # 官方插件 install 快速失败（负向留证）
#   ./terraform_plugin.sh install       # zip stage → apply（1 容器 28112）+ tfstate/outputs
#   ./terraform_plugin.sh reload        # replicas 1→2（execute_operation 增量 apply）
#   ./terraform_plugin.sh drift         # 手删容器 → drift 检出 → 收敛重建
#   ./terraform_plugin.sh uninstall     # destroy 零残留
#   ./terraform_plugin.sh               # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

DEP=tfd
STAGE=/tmp/handson08
WORK=$STAGE/work
TF_BIN=$(command -v terraform)

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

cleanup_containers() {
    docker rm -f $(docker ps -aq --filter name=cfy08-) >/dev/null 2>&1 || true
    return 0
}

stage_zip() {
    mkdir -p "$STAGE"
    (cd tf_module && zip -qr "$STAGE/tf-module.zip" .)
    # filesystem mirror: registry.terraform.io gets RST on this network now,
    # reuse the provider binary already downloaded by labs/01
    local mirror="$STAGE/tf-mirror"
    mkdir -p "$mirror/registry.terraform.io/kreuzwerker/docker/3.9.0/darwin_arm64"
    cp ../../labs/01_tf_docker_provider/configs/.terraform/providers/registry.terraform.io/kreuzwerker/docker/3.9.0/darwin_arm64/terraform-provider-docker_v3.9.0 \
        "$mirror/registry.terraform.io/kreuzwerker/docker/3.9.0/darwin_arm64/"
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
    TF_CLI_CFG="$STAGE/tfrc"
}

# tf_cli_config 借 inputs 传入：init 之后再 install（inputs 需在 init 时给全）
stage_and_init() {
    stage_zip
    cfy_run init init -b "$DEP" bp.yaml -i "tf_cli_config=$STAGE/tfrc"
}

do_official_neg() {
    step official-neg "官方 terraform 插件：validate 通过，install 因 Manager 硬依赖快速失败"
    cfy_run official-validate blueprints validate bp_official.yaml
    must_contain .logs/official-validate.log "validated successfully" "官方蓝图静态 validate 通过"
    reset_workdir
    cfy_run official-init init -b "${DEP}_official" bp_official.yaml
    cfy_run official-install executions start install -b "${DEP}_official" || true
    must_contain .logs/official-install.log \
        "Task failed 'cloudify_tf.tasks.install'.*(LOCAL_REST_CERT_FILE|inet_pton)" \
        "本地模式缺 Manager 运行时环境（证书/管理器 IP）→ 快速失败（负向留证）"
    reset_workdir
}

do_install() {
    step install "stage 模块 zip → script 包装 apply（replicas=1，端口 28112）"
    cleanup_containers
    reset_workdir
    stage_and_init
    cfy_run install executions start install -b "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    [ -f "$WORK/terraform.tfstate" ] || fail "terraform.tfstate 未出现在 $WORK"
    ok "terraform.tfstate 落在部署工作目录"
    [ "$(inst_attr "$DEP" tf_names | grep -c .)" = "1" ] || fail "tf_names runtime property 未写入"
    inst_attr "$DEP" tf_names | grep -q "cfy08-web-0" || fail "tf_names 应含 cfy08-web-0"
    ok "TF outputs 流回 runtime properties（含 cfy08-web-0）"
    local code
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://localhost:28112/")
    [ "$code" = "200" ] || fail "curl :28112 = $code 应 200"
    ok "TF 起的容器宿主可达（:28112 → 200）"
}

do_reload() {
    step reload "replicas 1→2：execute_operation 增量 apply（只动差集）"
    # -p parsing: whole-string JSON wins (plain_string_to_dict), so pass both
    # workflow parameters in one JSON object - key=value form keeps dict
    # values as strings
    cfy_run reload executions start execute_operation -b "$DEP" \
        -p '{"operation": "handson.interfaces.maintenance.apply",
             "operation_kwargs": {"replicas": 2},
             "allow_kwargs_override": true}'
    must_contain .logs/reload.log "'execute_operation' workflow execution succeeded" "reload 执行成功"
    local n
    n=$(docker ps -q --filter name=cfy08-web- | wc -l | tr -d ' ')
    [ "$n" = "2" ] || fail "容器数应 2（28112/28113），实为 $n"
    ok "增量 apply：容器 1→2（28112 + 28113）"
    local code
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://localhost:28113/")
    [ "$code" = "200" ] || fail "新容器 :28113 = $code 应 200"
    ok "新容器宿主可达（:28113 → 200）"
}

do_drift() {
    step drift "手删容器 → plan -detailed-exitcode 检出漂移 → 收敛重建"
    docker rm -f cfy08-web-0 >/dev/null
    cfy_run drift executions start execute_operation -b "$DEP" \
        -p '{"operation": "handson.interfaces.maintenance.drift_check",
             "operation_kwargs": {"replicas": 2}}'
    must_contain .logs/drift.log "drift detected .plan exit 2." "漂移被检出（plan 退出码 2）"
    [ "$(inst_attr "$DEP" drift_detected)" = "yes" ] || fail "drift_detected runtime property 应为 yes"
    ok "drift_detected = yes"
    [ "$(docker ps -q --filter name=cfy08-web- | wc -l | tr -d ' ')" = "2" ] || fail "收敛后容器应恢复 2 个"
    ok "收敛重建：容器恢复 2 个（TF 状态对账）"
}

do_uninstall() {
    step uninstall "delete 钩子 → terraform destroy → 零残留"
    cfy_run uninstall executions start uninstall -b "$DEP"
    must_contain .logs/uninstall.log "'uninstall' workflow execution succeeded" "uninstall 工作流成功"
    must_contain .logs/uninstall.log "tf destroy done" "delete 钩子执行了 terraform destroy"
    ok "terraform destroy 已执行（delete 钩子日志）"
    local residue
    residue=$(docker ps -aq --filter name=cfy08- | wc -l | tr -d ' ')
    [ "$residue" = "0" ] || fail "cfy08-* 容器残留 $residue"
    ok "零容器残留"
    cleanup_containers
}

case "${1:-all}" in
    official-neg) do_official_neg ;;
    install)      do_install ;;
    reload)       do_reload ;;
    drift)        do_drift ;;
    uninstall)    do_uninstall ;;
    all)
        do_official_neg
        do_install
        do_reload
        do_drift
        do_uninstall
        echo; echo "✅ 08 全部通过"
        ;;
    *) echo "用法: $0 [official-neg|install|reload|drift|uninstall|all]"; exit 1 ;;
esac
