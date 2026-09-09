#!/usr/bin/env bash
# =============================================================================
# 11 · 镜像瘦身与多架构 — 主演示脚本
#
# 前置：靶场在跑（本机 registry :5500 由实验 05 提供）
# ./image_slimming.sh sizes     构建三版镜像并输出体积对比表
# ./image_slimming.sh run       三版逐一跑起来做 HTTP 冒烟
# ./image_slimming.sh dive      dive 镜像分层分析（CI 模式）
# ./image_slimming.sh multiarch buildx 多架构构建并推私有 registry（5500）
# ./image_slimming.sh clean     清理演示容器与本地标签
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

REG="${REG:-localhost:5500}"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
have() { command -v "$1" >/dev/null; }

do_sizes() {
    step "sizes" "构建三版镜像（同一段业务代码，三种打包纪律）"
    docker build -f Dockerfile.full       -t slim:full       . 2>&1 | tail -1
    docker build -f Dockerfile.multistage -t slim:multistage . 2>&1 | tail -1
    docker build -f Dockerfile.distroless -t slim:distroless . 2>&1 | tail -1

    step "sizes" "体积对比表（真实的 docker images 数据）"
    printf "%-16s %10s\n" "版本" "体积" | sed 's/^/        /'
    for v in full multistage distroless; do
        local size
        size=$(docker image inspect "slim:$v" --format '{{.Size}}' | awk '{printf "%.0fMB", $1/1024/1024}')
        printf "%-16s %10s\n" "$v" "$size" | sed 's/^/        /'
    done
    note "结论：多阶段/精简基础镜像能砍掉 80%+ 体积；distroless 连 shell 都不留"
}

do_run() {
    step "run" "三版逐一 HTTP 冒烟（证明'小'没有牺牲'对'）"
    local i=28101
    for v in full multistage distroless; do
        docker rm -f "slim-$v" >/dev/null 2>&1 || true
        docker run -d --name "slim-$v" -p "$i:8080" "slim:$v" >/dev/null
        sleep 2
        note "$v :$i → $(curl -s "http://localhost:$i/healthz")"
        i=$((i+1))
    done
    for v in full multistage distroless; do docker rm -f "slim-$v" >/dev/null; done
}

do_dive() {
    step "dive" "分层分析：找镜像里的浪费（CI 模式输出效率分）"
    have dive || { echo "    [x] 缺 dive：brew install dive" >&2; exit 1; }
    # --ci 模式评估镜像效率（无交互）：PASS/FAIL + 效率规则判定
    CI=true dive "slim:full" --ci 2>/dev/null | tail -6 | LC_ALL=C sed 's/^/        /' || true
    note "对照：dive slim:multistage（交互模式可自行翻层查看浪费）"
}

do_multiarch() {
    step "multiarch" "buildx 双架构构建 → 推靶场私有 registry（:${REG}）"
    docker buildx build \
        --platform linux/amd64,linux/arm64 \
        -f Dockerfile.distroless \
        -t "$REG/slim/multiarch:1.0.0" \
        --push . 2>&1 | tail -3

    note "registry 目录：/v2/_catalog"
    curl -s "http://$REG/v2/_catalog" | sed 's/^/        /'
    note "manifest 显示两个平台（amd64 + arm64）"
    curl -s -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
        "http://$REG/v2/slim/multiarch/manifests/1.0.0" | jq -r '.manifests[].platform.architecture' 2>/dev/null | sed 's/^/        /'
    note "[ok] 同一 tag 双架构 —— 任何机器 docker pull 都拿到对的架构"
}

do_clean() {
    step "clean" "清理演示容器"
    for v in full multistage distroless; do docker rm -f "slim-$v" >/dev/null 2>&1 || true; done
    note "[ok] 演示容器已清理（镜像与 registry 内容保留供观察）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        sizes)     do_sizes ;;
        run)       do_run ;;
        dive)      do_dive ;;
        multiarch) do_multiarch ;;
        clean)     do_clean ;;
        all)       do_sizes; do_run; do_dive; do_multiarch; do_clean ;;
        *) echo "可用: sizes | run | dive | multiarch | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
