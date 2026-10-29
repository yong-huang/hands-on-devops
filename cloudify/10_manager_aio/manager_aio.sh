#!/usr/bin/env bash
# =============================================================================
# 10 · Manager 启动与首个托管部署 — AIO 社区版 7.0.1（arm64）
#
# 前置：镜像已由 ../scripts/fetch_manager_image.sh 载入（大层断流自救）。
# 用法：
#   ./manager_aio.sh up        # 起容器 + 轮询 cfy status 全 Active + profiles use
#   ./manager_aio.sh deploy    # upload 蓝图 + create + install + outputs 断言
#   ./manager_aio.sh rest      # REST API 断言（deployments 列表含部署）
#   ./manager_aio.sh persist   # docker restart 后部署仍在（持久化）
#   ./manager_aio.sh down      # 停容器（保留数据卷，供 11-13 复用）
#   ./manager_aio.sh all       # up → deploy → rest → persist（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../env.sh

IMAGE="cloudifyplatform/community-cloudify-manager-aio:7.0.1"
CTR=cfy-mgr
HOST_HTTP=28100
HOST_HTTPS=28101
DEP=m10
BPR=bp10
MGR=http://localhost:$HOST_HTTP
TENANT=default_tenant
# Manager profile 独立 workdir（不影响本地模式实验的 profile）
export CFY_WORKDIR="${CFY_WORKDIR:-$HOME/.cfy-handson/10_manager_aio}"

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

must_contain() {
    grep -qE "$2" "$1" || fail "$3（日志 $1 缺少 /$2/）"
    ok "$3"
}

# Manager profile 下 cfy 需要证书豁免（自签）
CFY_MGR() { "$CFY_CLI" --ssl false-policy "$@" 2>&1 | grep -vE "pkg_resources|import pkg"; }

wait_healthy() {  # 轮询 cfy status 全 Active（首启 3-5 分钟）
    local i=0
    while :; do
        i=$((i + 1))
        [ "$i" -gt 60 ] && fail "10 分钟内 Manager 未就绪（cfy status 未全 Active）"
        local out
        out=$("$CFY_CLI" --ssl false-policy status 2>/dev/null | grep -vE "pkg_resources|import pkg" || true)
        if echo "$out" | grep -q "Services +.*active\|+ Services" && \
           ! echo "$out" | grep -qE "inactive|busy|failed"; then
            echo "$out"
            return 0
        fi
        sleep 10
    done
}

do_up() {
    step up "启动 AIO 容器（--privileged + cgroup 挂载跑 systemd）"
    docker image inspect "$IMAGE" >/dev/null 2>&1 \
        || fail "镜像未载入——先跑 ../scripts/fetch_manager_image.sh 7.0.1 arm64"
    docker rm -f "$CTR" >/dev/null 2>&1 || true
    docker run -d --name "$CTR" --platform linux/arm64 \
        -p $HOST_HTTP:80 -p $HOST_HTTPS:443 \
        --tmpfs /run --tmpfs /run/lock \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cgroupns=host \
        --privileged "$IMAGE" >/dev/null
    ok "容器已启动（:$HOST_HTTP → 80）"
    step status "轮询服务全 Active"
    wait_healthy > .logs/status.log 2>&1 || fail "服务未就绪"
    ok "cfy status 全 Active（PostgreSQL/RabbitMQ/REST/mgmtworker/nginx）"
    mkdir -p .logs
    "$CFY_CLI" --ssl false-policy profiles use localhost:$HOST_HTTP -u admin -p admin -t "$TENANT" 2>&1 \
        | grep -vE "pkg_resources|import pkg" | tee .logs/profiles.log
    ok "profiles use 完成（admin/admin@${TENANT}）"
}

do_deploy() {
    step deploy "upload 蓝图 → 部署 → install（Manager 托管）"
    cfy_run upload blueprints upload bp.yaml -b "$BPR"
    must_contain .logs/upload.log "Uploaded blueprint" "蓝图上传成功"
    cfy_run create deployments create -b "$BPR" -d "$DEP" -i "greeting=hello"
    must_contain .logs/create.log "Deployment created" "部署创建成功"
    cfy_run install executions start install -d "$DEP"
    must_contain .logs/install.log "'install' workflow execution succeeded" "install 工作流成功"
    cfy_run outputs deployments outputs -d "$DEP"
    must_contain .logs/outputs.log "hello-from-cloudify-manager" "outputs 与脚本 runtime property 一致"
    ok "outputs 读回 hello-from-cloudify-manager"
    local st
    st=$("$CFY_CLI" --ssl false-policy executions list -d "$DEP" 2>/dev/null | grep -cE "terminated" || true)
    [ "$st" -ge 1 ] || fail "executions list 应有 terminated 状态"
    ok "executions list 状态 terminated（Manager 词汇，对应本地 completed）"
}

do_rest() {
    step rest "REST API v3.1 直查（curl + Tenant 头）"
    cfy_run rest-deployments curl -su admin:admin -H "Tenant: $TENANT" \
        "$MGR/api/v3.1/deployments" -o .logs/rest.json
    python3 -c "
import json
d = json.load(open('.logs/rest.json'))
ids = [i['id'] for i in d['items']]
assert '$DEP' in ids, 'deployments REST 无 $DEP: {}'.format(ids)
print('REST deployments 含 $DEP')
" || fail "REST 断言失败"
    ok "REST /api/v3.1/deployments 含 $DEP"
}

do_persist() {
    step persist "docker restart 后部署仍在（AIO 数据持久化）"
    docker restart "$CTR" >/dev/null
    ok "容器已重启"
    local i=0
    while :; do
        i=$((i + 1)); [ "$i" -gt 60 ] && fail "重启后 10 分钟未恢复"
        if "$CFY_CLI" --ssl false-policy deployments list 2>/dev/null | grep -q "$DEP"; then
            break
        fi
        sleep 10
    done
    cfy_run deployments-after deployments list -d "$DEP"
    must_contain .logs/deployments-after.log "$DEP" "重启后部署仍在"
}

do_down() {
    step down "停容器（保留容器与数据，供项目 11-13 复用）"
    docker stop "$CTR" >/dev/null
    ok "已停止（docker start $CTR 可复活）"
}

case "${1:-all}" in
    up)      do_up ;;
    deploy)  do_deploy ;;
    rest)    do_rest ;;
    persist) do_persist ;;
    down)    do_down ;;
    all)
        mkdir -p .logs
        do_up
        do_deploy
        do_rest
        do_persist
        echo; echo "✅ 10 全部通过"
        ;;
    *) echo "用法: $0 [up|deploy|rest|persist|down|all]"; exit 1 ;;
esac
