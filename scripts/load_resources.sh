#!/usr/bin/env bash
# =============================================================================
# load_resources.sh — 系列公共镜像预载脚本
#
# 解决本系列最普遍的环境阻塞：大镜像拉取慢/偶发失败。
# 幂等：已存在的镜像跳过；失败自动换 daocloud 镜像源重试一次。
# 用法：
#   ./scripts/load_resources.sh            # 预载全部实验所需镜像
#   ./scripts/load_resources.sh 16 18      # 只预载指定实验
#   ONLY=gitea/jenkins ./scripts/load_resources.sh   # 拉指定镜像（绕过实验映射）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

MIRROR="docker.m.daocloud.io"

# 实验 → 镜像列表（library/ 官方镜像写全限定名，与 daocloud 补前缀规则一致）
declare -A LAB_IMAGES=(
    [01]="docker.io/library/nginx:1.27-alpine"
    [02]="docker.io/library/nginx:1.27-alpine"
    [03]="docker.io/minio/minio:latest docker.io/library/busybox:1.36"
    [04]="docker.io/library/nginx:1.27-alpine"
    [05]="docker.io/library/nginx:1.27-alpine docker.io/library/registry:2 docker.io/minio/minio:latest docker.io/gitea/gitea:1.22"
    [06]="docker.io/library/nginx:1.27-alpine docker.io/library/python:3.12-alpine"
    [07]="docker.io/library/nginx:1.27-alpine docker.io/library/python:3.12-alpine"
    [08]="docker.io/library/debian:12-slim"
    [09]="docker.io/chef/chef:latest"
    [10]="docker.io/puppet/puppet-agent:latest"
    [11]="docker.io/library/python:3.12 docker.io/library/python:3.12-alpine docker.io/gcr.io/distroless/python3-debian12:latest"
    [12]="docker.io/library/nginx:1.27-alpine docker.io/library/registry:2 docker.io/library/alpine:3.20 docker.io/library/python:3.12-alpine"
    [13]="docker.io/library/registry:2 docker.io/library/nginx:1.27-alpine"
    [14]="docker.io/library/registry:2 docker.io/library/alpine:3.20"
    [15]="docker.io/library/registry:2 docker.io/library/nginx:1.27-alpine docker.io/library/alpine:3.20"
    [16]="docker.io/jenkins/jenkins:lts-jdk17 docker.io/library/alpine:3.20 docker.io/library/docker:27-cli"
    [17]="docker.io/jenkins/jenkins:lts-jdk17 docker.io/library/docker:27-cli"
    [18]="docker.io/gitea/gitea:1.22 docker.io/gitea/act_runner:latest docker.io/library/docker:27-cli docker.io/library/python:3.12-alpine"
    [19]="docker.io/woodpeckerci/woodpecker-server:latest docker.io/woodpeckerci/woodpecker-agent:latest docker.io/library/alpine:3.20"
    [20]="docker.io/gitea/gitea:1.22 docker.io/gitea/act_runner:latest docker.io/library/docker:27-cli docker.io/library/python:3.12-alpine"
    [21]="docker.io/library/nginx:1.27-alpine docker.io/kindest/node:v1.31.0"
    [22]="docker.io/library/alpine:3.20"
    [23]="docker.io/library/alpine:3.20"
    [24]="docker.io/library/nginx:1.27-alpine"
    [25]="docker.io/library/alpine:3.20"
    [26]="docker.io/prom/prometheus:latest docker.io/grafana/grafana:latest"
    [27]="docker.io/grafana/loki:latest docker.io/grafana/promtail:latest docker.io/grafana/grafana:latest"
    [28]="docker.io/library/nginx:1.27-alpine"
    [29]="docker.io/library/registry:2 docker.io/minio/minio:latest docker.io/gitea/gitea:1.22 docker.io/library/nginx:1.27-alpine"
    [30]="docker.io/library/registry:2 docker.io/minio/minio:latest docker.io/gitea/gitea:1.22 docker.io/prom/prometheus:latest docker.io/grafana/grafana:latest docker.io/grafana/loki:latest docker.io/grafana/promtail:latest"
)

have() { docker image inspect "$1" >/dev/null 2>&1; }

pull_one() {
    local img="$1"
    have "$img" && { echo "  [=] 已存在 $img"; return 0; }
    echo "  [+] 拉取 $img"
    if ! docker pull -q "$img"; then
        # daocloud 规则：library/ 官方镜像要补 library/ 前缀，其余命名空间原样替换
        local path="${img#docker.io/}" fallback
        if [[ "$path" == */* ]]; then fallback="$MIRROR/$path"
        else fallback="$MIRROR/library/$path"; fi
        echo "  [!] 直连失败，换镜像源 ${MIRROR} 重试"
        if docker pull -q "$fallback"; then
            docker tag "$fallback" "$img" && docker rmi "$fallback" || true
        else
            return 1
        fi
    fi
}

main() {
    command -v docker >/dev/null || { echo "需要 docker" >&2; exit 1; }
    docker info >/dev/null 2>&1 || { echo "docker daemon 未运行" >&2; exit 1; }

    if [ -n "${ONLY:-}" ]; then
        for img in $ONLY; do pull_one "$img"; done
        return 0
    fi

    local labs=("$@")
    [ ${#labs[@]} -eq 0 ] && labs=($(printf '%s\n' "${!LAB_IMAGES[@]}" | sort -n))

    local fail=0
    for n in "${labs[@]}"; do
        [ -z "${LAB_IMAGES[$n]:-}" ] && continue
        echo "=====> 实验 $n 镜像"
        for img in ${LAB_IMAGES[$n]}; do
            pull_one "$img" || { echo "  [x] $img 拉取失败"; fail=1; }
        done
    done
    [ $fail -eq 0 ] && echo "=====> 全部镜像就绪" || { echo "=====> 部分镜像失败，可重跑本脚本" >&2; exit 1; }
}

main "$@"
