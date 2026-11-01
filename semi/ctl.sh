#!/usr/bin/env bash
# semi/ctl.sh · 半导体 CI/CD 系列容器一键启停（本系列全部常驻容器）
# 用法：./ctl.sh start | stop | status
# 容器清单（与各实验脚本创建的一致）：
#   gitlab                    平台（01，compose 项目 semi-gitlab）
#   runner-eda / runner-fpga  Runner 农场（05）
#   webhook-listener          事件观测（04）
#   semi-farm-control-plane   kind 集群节点（07，K8s executor 的宿主）
# OrbStack UI 分组：各脚本创建容器时带 --label dev.orbstack.group=semi-cicd；
# gitlab 由 compose 管理，UI 里天然是 semi-gitlab 组。
set -uo pipefail
cd "$(dirname "$0")"

CONTAINERS=(gitlab runner-eda runner-fpga webhook-listener semi-farm-control-plane)
KUBECONFIG="$PWD/07_kind_farm/.kubeconfig"

do_start() {
    echo "=====> 启动本系列容器"
    local need_reconf=0
    for c in "${CONTAINERS[@]}"; do
        local st
        st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
        case "$st" in
            running) echo "  [  =] $c 已在运行" ;;
            missing) echo "  [skip] $c 不存在（先跑对应实验的 up）" ;;
            *)       docker start "$c" >/dev/null && echo "  [ok]   $c 已启动" ;;
        esac
        [ "$c" = "gitlab" ] && need_reconf=1
    done
    if [ "$need_reconf" = 1 ]; then
        echo "=====> 等待 GitLab 就绪（停机后首启需 1-3 分钟）"
        ./01_gitlab_up/scripts/healthcheck.sh 2>&1 | tail -1
    fi
    echo "[ok] 平台就绪：http://localhost:28200"
}

do_stop() {
    echo "=====> 停止本系列容器（数据卷全部保留）"
    for c in "${CONTAINERS[@]}"; do
        docker stop "$c" >/dev/null 2>&1 && echo "  [ok]   $c 已停" || echo "  [skip] $c 未在运行"
    done
    echo "[ok] 全部停止（重新开始：./ctl.sh start）"
}

do_status() {
    printf '%-26s %s\n' "容器" "状态"
    for c in "${CONTAINERS[@]}"; do
        local st
        st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
        printf '%-26s %s\n' "$c" "$st"
    done
    curl -s -o /dev/null -w '\nGitLab: HTTP %{http_code}\n' --max-time 8 \
        http://localhost:28200/users/sign_in || true
}

main() {
    local target="${1:-status}"
    case "${target}" in
        start)  do_start ;;
        stop)   do_stop ;;
        status) do_status ;;
        *) echo "用法: $0 start | stop | status" >&2; exit 1 ;;
    esac
}
main "$@"
