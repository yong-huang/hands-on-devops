#!/usr/bin/env bash
# semi/ctl.sh · 半导体 CI/CD 系列容器一键启停（本系列全部常驻容器）
# 用法：./ctl.sh start | stop | status | disk | scrub
# 容器清单（与各实验脚本创建的一致）：
#   disk  磁盘占用分类报表（只读）
#   scrub 分级回收大件（默认 dry-run 列表；--apply 真删）
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


do_disk() {
    echo "=====> 磁盘占用报表（只读）"
    echo "-- 宿主 semi（可再生工作副本/备份）--"
    du -sh 03_rtl_lfs/.work 08_lint_gate/.work 23_dr/data \
        25_capstone/data_backup 22_airgap/data 2>/dev/null | sed 's/^/  /'
    echo "-- GitLab 卷内 --"
    docker exec gitlab du -sh /var/opt/gitlab/gitlab-rails/shared/lfs-objects \
        /var/opt/gitlab/gitlab-rails/shared/registry 2>/dev/null | sed 's/^/  /'
    echo "-- Docker 总量（跨系列共享，慎清）--"
    docker system df 2>/dev/null | sed 's/^/  /' | head -6
    echo "-- /tmp 残留（semi 相关）--"
    du -sh /tmp/rtl_clone_full /tmp/rtl_clone_skip /tmp/fpga_art*.zip \
        /tmp/rel.tar.gz /tmp/unit_art.zip /tmp/cq.zip /tmp/bitstream_art.zip \
        /tmp/cosign /tmp/cosign.partial 2>/dev/null | sed 's/^/  /' || true
    echo "说明：./ctl.sh scrub --apply 可回收宿主 semi 大件；GitLab 卷内 LFS 走 rtl_lfs.sh clean"
}

do_scrub() {
    # ⚠️ 默认 dry-run 只列不动；--apply 才真删（本轮教训：删除循环必须包在开关里）
    local apply="${2:-}"
    echo "=====> scrub（${apply:+真删模式}${apply:-dry-run 列表，加 --apply 真删}）"
    local freed=0

    # 1) /tmp semi 残留
    for f in /tmp/rtl_clone_full /tmp/rtl_clone_skip /tmp/fpga_art.zip \
             /tmp/fpga_art_full.zip /tmp/rel.tar.gz /tmp/unit_art.zip \
             /tmp/cq.zip /tmp/bitstream_art.zip /tmp/cosign /tmp/cosign.partial; do
        [ -e "$f" ] || continue
        sz=$(du -sk "$f" | cut -f1)
        if [ "$apply" = "--apply" ]; then
            rm -rf "$f"; freed=$((freed+sz)); echo "  [del] $f ($((sz/1024))MB)"
        else
            echo "  [will-del] $f ($((sz/1024))MB)"
        fi
    done

    # 2) 宿主工作副本（up 可再生）
    for d in 03_rtl_lfs/.work 08_lint_gate/.work; do
        [ -d "$d" ] || continue
        sz=$(du -sk "$d" | cut -f1)
        if [ "$apply" = "--apply" ]; then
            rm -rf "$d"; freed=$((freed+sz)); echo "  [del] $d ($((sz/1024))MB)"
        else
            echo "  [will-del] $d ($((sz/1024))MB)"
        fi
    done

    # 3) 25_capstone/data_backup（23_dr/data 已有母本）
    d=25_capstone/data_backup
    if [ -d "$d" ]; then
        sz=$(du -sk "$d" | cut -f1)
        if [ "$apply" = "--apply" ]; then
            rm -rf "$d"; freed=$((freed+sz)); echo "  [del] $d ($((sz/1024))MB)"
        else
            echo "  [will-del] $d ($((sz/1024))MB)"
        fi
    fi

    # 4) 23_dr 备份保留最新 1 份（secrets/gitlab.rb 不动）
    keep=$(ls -t 23_dr/data/*_gitlab_backup.tar 2>/dev/null | head -1)
    for t in 23_dr/data/*_gitlab_backup.tar; do
        [ -e "$t" ] || continue
        sz=$(du -sk "$t" | cut -f1)
        if [ "$apply" = "--apply" ] && [ "$t" != "$keep" ]; then
            rm -f "$t"; freed=$((freed+sz)); echo "  [del] $t ($((sz/1024))MB)"
        else
            echo "  [keep] $t ($((sz/1024))MB)"
        fi
    done

    echo
    if [ "$apply" = "--apply" ]; then
        echo "[ok] 共回收约 $((freed/1024)) MB；GitLab 卷内 LFS（9G）要清走 rtl_lfs.sh clean（会删项目）"
    else
        echo "[dry-run 结束] 共 $((freed/1024)) MB 可回收——真删：./ctl.sh scrub --apply"
    fi
}

main() {
    local target="${1:-status}"
    case "${target}" in
        start)  do_start ;;
        stop)   do_stop ;;
        status) do_status ;;
        disk)   do_disk ;;
        scrub)  do_scrub "$@" ;;
        *) echo "用法: $0 start | stop | status | disk | scrub" >&2; exit 1 ;;
    esac
}
main "$@"
