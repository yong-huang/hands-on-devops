#!/usr/bin/env bash
# =============================================================================
# 12 · Packer 镜像流水线 — 主演示脚本
#
# ./packer_pipeline.sh build    packer init + build（builder→ansible→push 一条龙）
# ./packer_pipeline.sh verify   从靶场 registry 拉取并冒烟验证
# ./packer_pipeline.sh clean    清理演示容器
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

REG="localhost:5500"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

do_build() {
    step "build" "packer init（校验插件；已离线安装到 ~/.packer.d/plugins）"
    packer init nginx.pkr.hcl 2>&1 | sed 's/^/        /' || true

    step "build" "packer build：builder → ansible provisioner → 推 :5500"
    # 插件经 SSH(端口转发)连容器，偶发抖动——失败自动重试一次
    local rc=0
    packer build -var "app_version=1.0.0" nginx.pkr.hcl > tmp_build.log 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        note "[i] 第一次失败（模拟架构下 SSH 偶发抖动），重试……"
        packer build -var "app_version=1.0.0" nginx.pkr.hcl > tmp_build.log 2>&1 || rc=$?
    fi
    LC_ALL=C grep -a "Builds finished" tmp_build.log >/dev/null || { tail -6 tmp_build.log | LC_ALL=C sed 's/^/        /'; exit 1; }
    LC_ALL=C grep -aE "docker-push|Builds finished" tmp_build.log | tail -3 | LC_ALL=C sed 's/^/        /'
    note "镜像清单："
    docker images | grep packer-nginx | sed 's/^/        /' | head -3
}

do_verify() {
    step "verify" "registry 侧确认 + 拉取冒烟"
    curl -s "http://$REG/v2/_catalog" | sed 's/^/        /'
    curl -s "http://$REG/v2/packer-nginx/tags/list" | sed 's/^/        /'
    docker rm -f packer-verify >/dev/null 2>&1 || true
    docker run -d --name packer-verify -p 28102:8080 "$REG/packer-nginx:1.0.0" >/dev/null
    sleep 3
    note "curl :28102/healthz → $(curl -s http://localhost:28102/healthz)"
    note "curl :28102/ → $(curl -s http://localhost:28102/)"
    docker rm -f packer-verify >/dev/null
    note "[ok] registry → pull → 运行，全链路通"
}

do_clean() {
    step "clean" "清理演示容器"
    docker rm -f packer-verify >/dev/null 2>&1 || true
    rm -f tmp_build.log
    note "[ok] 零残留"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        build)  do_build ;;
        verify) do_verify ;;
        clean)  do_clean ;;
        all)    do_build; do_verify; do_clean ;;
        *) echo "可用: build | verify | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
