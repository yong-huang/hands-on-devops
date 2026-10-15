#!/usr/bin/env bash
# =============================================================================
# docker-env.sh — 探测可用的 docker socket 并导出 DOCKER_HOST（被各实验 source）
#
# 为什么需要它：
#   docker CLI 有 context 机制（docker context ls），总能连对 daemon；
#   但 Go/SDK 类客户端（terraform docker provider、ansible 的 docker 连接插件）
#   不读 context，默认只认 /var/run/docker.sock。而这台机器上它是软链，
#   可能指向一个未运行的 daemon（如 Docker Desktop）→ 客户端表现为"永远卡住"。
#
# 本脚本逐个探测候选 socket 的 /_ping，把第一个响应正常的导出为 DOCKER_HOST。
# 用户已显式设置 DOCKER_HOST 时不覆盖。
# =============================================================================
_hands_on_docker_env() {
    [ -n "${DOCKER_HOST:-}" ] && return 0
    local s
    # 本仓库默认跑 OrbStack（2026-09 起）：原生 arm64、启动快、省电。
    # DOCKERDESKTOP=1 时切回 Docker Desktop 优先；用户显式设置 DOCKER_HOST 时不覆盖。
    if [ "${DOCKERDESKTOP:-0}" = "1" ]; then
        for s in "$HOME/.docker/run/docker.sock" "/var/run/docker.sock" "$HOME/.orbstack/run/docker.sock"; do
            [ -S "$s" ] || continue
            if curl -sS --max-time 3 --unix-socket "$s" http://localhost/_ping >/dev/null 2>&1; then
                export DOCKER_HOST="unix://$s"
                return 0
            fi
        done
        echo "    [!] Docker Desktop 未响应（是否已启动 Docker Desktop？）" >&2
        return 1
    fi
    for s in "$HOME/.orbstack/run/docker.sock" "/var/run/docker.sock" "$HOME/.docker/run/docker.sock"; do
        [ -S "$s" ] || continue
        if curl -sS --max-time 3 --unix-socket "$s" http://localhost/_ping >/dev/null 2>&1; then
            export DOCKER_HOST="unix://$s"
            return 0
        fi
    done
    echo "    [!] OrbStack / Docker Desktop 的 socket 均无响应，请先启动 OrbStack.app（orb start）" >&2
    return 1
}
_hands_on_docker_env
