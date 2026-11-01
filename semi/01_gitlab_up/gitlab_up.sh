#!/usr/bin/env bash
# semi/01_gitlab_up · GitLab CE 单机生命周期总控
# 用法：./gitlab_up.sh up | status | verify | stop | start | clean
#   up     启动平台 + 轮询就绪 + 提示 root 初始密码（首次启动 4-6 分钟）
#   status 服务状态 + 内存占用（日常巡检）
#   verify 清单验收断言（平台可用性 / 服务完整性 / puma 减配 / 内存限额与占用）
#   stop   停容器（容器与数据卷都保留，./gitlab_up.sh start 快速恢复）
#   start  恢复已停止的容器（秒级，免重新 reconfigure）
#   clean  删除容器 + 数据卷（平台清零！仅想重来时用）
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE="docker compose -f configs/docker-compose.yml"
step() { echo; echo "=====> [$1] $2"; }

do_up() {
    step up "启动 GitLab CE（首次运行会先拉 ~3GB 镜像）"
    $COMPOSE up -d
    ./scripts/healthcheck.sh
    step info "root 初始密码（首次启动后 24h 内可读，登录后请立即改掉）"
    if docker exec gitlab test -f /etc/gitlab/initial_root_password; then
        docker exec gitlab grep 'Password:' /etc/gitlab/initial_root_password | sed 's/^/  /'
        echo "  （文件已过 24h 则删除是正常的：账号仍在，密码忘了用下面命令重置）"
        echo "  docker exec -it gitlab gitlab-rake 'gitlab:password:reset[root]'"
    else
        echo "  initial_root_password 不存在：重置 root 密码 →"
        echo "  docker exec -it gitlab gitlab-rake 'gitlab:password:reset[root]'"
    fi
}

do_status() {
    step status "gitlab-ctl 服务状态（期望全部 run，无 down）"
    docker exec gitlab gitlab-ctl status
    step status "容器资源占用（限额 4500MB）"
    docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' gitlab
}

# ---------- 验收断言（docs/cicd-semi.md 项目 1）----------
fail()  { echo "  [fail] $1"; FAILED=1; }
pass()  { echo "  [ok]   $1"; }
do_verify() {
    local FAILED=0
    step verify "清单验收断言"

    # ① 前半：登录页 200（平台可用）+ API 401（rails 链路活性）
    #    新版 GitLab CE 的 /-/readiness、/-/health 默认下线（实测 404），改用真实信号
    if curl -sf --max-time 10 http://localhost:28200/users/sign_in -o /dev/null; then
        pass "users/sign_in：HTTP 200（平台可用）"
    else
        fail "users/sign_in 非 2xx（服务没起来或还在启动）"
    fi
    code_api=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:28200/api/v4/version)
    if [ "$code_api" = "401" ]; then
        pass "api/v4/version：HTTP 401（rails 活性正常，未带 token 理应 401）"
    else
        fail "api/v4/version 返回 ${code_api}（期望 401）"
    fi

    # ① 后半：gitlab-ctl status 全部 run、无 down（核心服务 ≥8 个）
    local status_line_count down_count
    status_line_count=$(docker exec gitlab gitlab-ctl status 2>/dev/null | grep -c '^run:' || true)
    down_count=$(docker exec gitlab gitlab-ctl status 2>/dev/null | grep -c 'down' || true)
    if [ "$status_line_count" -ge 8 ] && [ "$down_count" -eq 0 ]; then
        pass "gitlab-ctl status：${status_line_count} 个服务全部 run，无 down"
    else
        fail "gitlab-ctl status：run=${status_line_count}（需≥8），down=${down_count}（需=0）"
    fi

    # ② 前半：内存减配 —— 仓库文件与容器内生效文件都要有 worker_processes = 2
    if grep -q "puma\['worker_processes'\] = 2" configs/gitlab.rb &&
       docker exec gitlab grep -q "puma\['worker_processes'\] = 2" /etc/gitlab/gitlab.rb; then
        pass "puma worker_processes = 2（仓库 configs/gitlab.rb 与容器内一致）"
    else
        fail "puma worker_processes = 2 未在 configs/gitlab.rb 或容器内 /etc/gitlab/gitlab.rb 生效"
    fi

    # ② 后半：内存限额 4.5GB 生效，且实际占用 < 6GB
    local stats usage_human usage_num usage_unit limit_bytes
    stats=$(docker stats --no-stream --format '{{.MemUsage}}' gitlab)   # "3.21GiB / 4.5GiB"
    usage_human="${stats%% *}"
    limit_bytes=$(docker inspect gitlab --format '{{.HostConfig.Memory}}')
    if [ "$limit_bytes" -eq 4718592000 ]; then                          # 4500 * 1024 * 1024
        pass "内存限额生效：4500MiB（docker stats 显示 ${stats}）"
    else
        fail "内存限额未生效：HostConfig.Memory = ${limit_bytes}（期望 4718592000）"
    fi
    # bash 3.2 兼容：不支持 ${var:0:-3} 负向子串，用长度运算
    usage_num="${usage_human:0:${#usage_human}-3}"; usage_unit="${usage_human:${#usage_human}-3}"
    case "$usage_unit" in
        GiB) [ "$(awk "BEGIN{print ($usage_num < 6)}")" = 1 ] ;;
        MiB) true ;;                                                     # MiB 量级必然 < 6GB
        *)   [ "$(awk "BEGIN{print ($usage_num < 6144)}")" = 1 ] ;;      # KB 兜底
    esac && pass "实际内存占用 ${usage_human} < 6GB" ||
        fail "实际内存占用 ${usage_human} ≥ 6GB（减配配置没起效？）"

    echo
    if [ "$FAILED" -eq 0 ]; then
        echo "[ok] 项目 1 全部验收断言通过"
    else
        echo "[fail] 有断言未过，见上"; exit 1
    fi
}

do_stop()  { step stop "停止容器（compose stop：容器与数据卷都保留）"; $COMPOSE stop; }
do_start() { step start "恢复容器（秒级，免重新 reconfigure）"; $COMPOSE start; }

do_clean() {
    step clean "删除容器与数据卷（平台清零，含仓库/密钥/初始密码）"
    $COMPOSE down -v
    echo "[ok] 已清零。重建：./gitlab_up.sh up"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)     do_up ;;
        status) do_status ;;
        verify) do_verify ;;
        stop)   do_stop ;;
        start)  do_start ;;
        clean)  do_clean ;;
        all)    do_up; do_verify ;;    # 平台是长驻载体：all 不含 clean
        *) echo "用法: $0 up | status | verify | stop | start | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
