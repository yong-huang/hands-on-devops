#!/bin/sh
# =============================================================================
# load_resources.sh — 系列公共镜像预载脚本
#
# 解决本系列最普遍的环境阻塞：大镜像拉取慢/偶发失败。
# 幂等：已存在的镜像跳过；失败自动换 daocloud 镜像源重试，
#       minio 系镜像再退官方主发布源 quay.io（Docker Hub 镜像源常对其 403）。
# 兼容性：纯 POSIX sh（macOS 自带 /bin/sh 即 bash 3.2，无关联数组，
#         勿引入 bash 特性，否则 sh 调用会退化为索引数组并触发八进制报错）。
# 用法：
#   ./scripts/load_resources.sh            # 预载全部实验所需镜像
#   ./scripts/load_resources.sh 16 18      # 只预载指定实验
#   ONLY=gitea/jenkins ./scripts/load_resources.sh   # 拉指定镜像（绕过实验映射）
# =============================================================================
set -eu
cd "$(dirname "$0")/.."

MIRROR="docker.m.daocloud.io"

# 实验 → 镜像列表（library/ 官方镜像写全限定名，与 daocloud 补前缀规则一致）
lab_images() {
    case "$1" in
        01) echo "docker.io/library/nginx:1.27-alpine" ;;
        02) echo "docker.io/library/nginx:1.27-alpine" ;;
        03) echo "docker.io/minio/minio:latest docker.io/minio/mc:latest docker.io/library/busybox:1.36" ;;
        04) echo "docker.io/library/nginx:1.27-alpine" ;;
        05) echo "docker.io/library/nginx:1.27-alpine docker.io/library/registry:2 docker.io/minio/minio:latest docker.io/gitea/gitea:1.22" ;;
        06) echo "docker.io/library/nginx:1.27-alpine docker.io/library/python:3.12-alpine" ;;
        07) echo "docker.io/library/nginx:1.27-alpine docker.io/library/python:3.12-alpine" ;;
        08) echo "docker.io/library/debian:12-slim" ;;
        09) echo "docker.io/chef/chef:latest" ;;
        10) echo "docker.io/puppet/puppet-agent:latest" ;;
        11) echo "docker.io/library/python:3.12 docker.io/library/python:3.12-alpine docker.io/gcr.io/distroless/python3-debian12:latest" ;;
        12) echo "docker.io/library/nginx:1.27-alpine docker.io/library/registry:2 docker.io/library/alpine:3.20 docker.io/library/python:3.12-alpine" ;;
        13) echo "docker.io/library/registry:2 docker.io/library/nginx:1.27-alpine" ;;
        14) echo "docker.io/library/registry:2 docker.io/library/alpine:3.20" ;;
        15) echo "docker.io/library/registry:2 docker.io/library/nginx:1.27-alpine docker.io/library/alpine:3.20" ;;
        16) echo "docker.io/jenkins/jenkins:lts-jdk17 docker.io/library/alpine:3.20 docker.io/library/docker:27-cli" ;;
        17) echo "docker.io/jenkins/jenkins:lts-jdk17 docker.io/library/docker:27-cli" ;;
        18) echo "docker.io/gitea/gitea:1.22 docker.io/gitea/act_runner:latest docker.io/library/docker:27-cli docker.io/library/python:3.12-alpine" ;;
        19) echo "docker.io/woodpeckerci/woodpecker-server:latest docker.io/woodpeckerci/woodpecker-agent:latest docker.io/library/alpine:3.20" ;;
        20) echo "docker.io/gitea/gitea:1.22 docker.io/gitea/act_runner:latest docker.io/library/docker:27-cli docker.io/library/python:3.12-alpine" ;;
        21) echo "docker.io/library/nginx:1.27-alpine docker.io/kindest/node:v1.31.0" ;;
        22) echo "docker.io/library/alpine:3.20" ;;
        23) echo "docker.io/library/alpine:3.20" ;;
        24) echo "docker.io/library/nginx:1.27-alpine" ;;
        25) echo "docker.io/library/alpine:3.20" ;;
        26) echo "docker.io/prom/prometheus:latest docker.io/grafana/grafana:latest" ;;
        27) echo "docker.io/grafana/loki:latest docker.io/grafana/promtail:latest docker.io/grafana/grafana:latest" ;;
        28) echo "docker.io/library/nginx:1.27-alpine" ;;
        29) echo "docker.io/library/registry:2 docker.io/minio/minio:latest docker.io/gitea/gitea:1.22 docker.io/library/nginx:1.27-alpine" ;;
        30) echo "docker.io/library/registry:2 docker.io/minio/minio:latest docker.io/gitea/gitea:1.22 docker.io/prom/prometheus:latest docker.io/grafana/grafana:latest docker.io/grafana/loki:latest docker.io/grafana/promtail:latest" ;;
    esac
}

have() { docker image inspect "$1" >/dev/null 2>&1; }

pull_one() {
    img=$1
    if have "$img"; then
        echo "  [=] 已存在 $img"
        return 0
    fi
    echo "  [+] 拉取 $img"
    if docker pull -q "$img"; then
        return 0
    fi

    # daocloud 规则：library/ 官方镜像要补 library/ 前缀，其余命名空间原样替换
    path=${img#docker.io/}
    case "$path" in
        */*) fallback="$MIRROR/$path" ;;
        *) fallback="$MIRROR/library/$path" ;;
    esac
    echo "  [!] 直连失败，换镜像源 $MIRROR 重试"
    if docker pull -q "$fallback"; then
        docker tag "$fallback" "$img" && docker rmi "$fallback" || true
        return 0
    fi

    # minio 官方主发布在 quay.io，可绕过 Docker Hub 镜像源
    case "$img" in
        docker.io/minio/*)
            alt="quay.io/minio/${img#docker.io/minio/}"
            echo "  [!] 仍失败，改走官方源 quay.io"
            if docker pull -q "$alt"; then
                docker tag "$alt" "$img" && docker rmi "$alt" || true
                return 0
            fi
            ;;
    esac
    return 1
}

main() {
    command -v docker >/dev/null || { echo "需要 docker" >&2; exit 1; }
    docker info >/dev/null 2>&1 || { echo "docker daemon 未运行" >&2; exit 1; }

    if [ -n "${ONLY:-}" ]; then
        for img in $ONLY; do
            pull_one "$img" || { echo "  [x] $img 拉取失败"; exit 1; }
        done
        return 0
    fi

    labs=$(seq -w 1 30)   # 全部实验编号；未在 lab_images 映射里的编号自动跳过
    if [ $# -gt 0 ]; then labs="$*"; fi

    fail=0
    for n in $labs; do
        imgs=$(lab_images "$n")
        [ -n "$imgs" ] || continue
        echo "=====> 实验 $n 镜像"
        for img in $imgs; do
            pull_one "$img" || { echo "  [x] $img 拉取失败"; fail=1; }
        done
    done
    if [ "$fail" -eq 0 ]; then
        echo "=====> 全部镜像就绪"
    else
        echo "=====> 部分镜像失败，可重跑本脚本" >&2
        exit 1
    fi
}

main "$@"
