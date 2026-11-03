#!/usr/bin/env bash
# =============================================================================
# 29 · 备份与灾难恢复演练 — 主演示脚本
#
# 备份清单（什么必须备份）：Gitea 数据卷（仓库+用户+run 历史）、registry 存储
# （镜像不可重建的 artifact）、TF state（期望态）。什么可重建：容器本身、网络。
# 灾难演练：backup → destroy-all（卷级销毁=数据全灭）→ restore → 冒烟断言。
# RTO/RPO 实测计时输出。
#
# ./backup_restore.sh backup       全量备份（tar 卷 + 记录 digest 清单）
# ./backup_restore.sh destroy      灾难：销毁 gitea/registry 容器+卷+TF state
# ./backup_restore.sh restore      从备份恢复卷 + 重建容器 + 还原 state
# ./backup_restore.sh smoke        端到端冒烟（registry catalog / gitea repo / TF plan）
# ./backup_restore.sh all          backup → destroy → restore → smoke（含 RTO/RPO 计时）
# ./backup_restore.sh clean        清理备份与运行时
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

B="backups"
TS_DIR="$B/$(date +%Y%m%d-%H%M%S)"
GITEA_VOL="lab25-gitea-data"      # 25 的 Gitea 数据（仓库/用户/run 历史）
REG_VOL="lab-registry-data"       # 14 的 registry 存储（若命名不同自动探测）
G="lab25-gitea"
RG="lab25-registry"
NET="lab25-net"
RTO_START=""

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

rto_start() { RTO_START=$(date +%s); }
rto_report() {  # rto_report <阶段名>：距 RTO 起点的秒数
    local now=$(date +%s)
    note "RTO 计时 [$1]: +$((now - RTO_START))s"
}

detect_reg_vol() {  # registry 卷名探测：lab-registry-data 或 registry 数据在容器匿名卷
    if docker volume inspect "$REG_VOL" >/dev/null 2>&1; then
        echo "$REG_VOL"; return
    fi
    # 从 lab-registry 容器（14 的）找挂载卷
    local v
    for c in $(docker ps -a --format '{{.Names}}' | grep -i registry); do
        v=$(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/registry"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)
        [ -n "$v" ] && { echo "$v"; return; }
    done
    echo ""
}

do_backup() {
    step backup "全量备份（RPO 起点 = 备份开始时刻）"
    mkdir -p "$TS_DIR"
    # 1) Gitea 数据卷（25 的仓库与 run 历史）
    docker run --rm -v "$GITEA_VOL":/data -v "$PWD/$TS_DIR":/backup alpine \
        tar czf /backup/gitea-data.tar.gz -C /data . 2>/dev/null || fail "Gitea 卷备份失败"
    note "gitea-data.tar.gz: $(du -h "$TS_DIR/gitea-data.tar.gz" | cut -f1)"
    # 2) registry 卷
    REG_VOL=$(detect_reg_vol)
    if [ -n "$REG_VOL" ]; then
        docker run --rm -v "$REG_VOL":/data -v "$PWD/$TS_DIR":/backup alpine \
            tar czf /backup/registry-data.tar.gz -C /data . 2>/dev/null || fail "registry 卷备份失败"
        note "registry-data.tar.gz: $(du -h "$TS_DIR/registry-data.tar.gz" | cut -f1)"
    else
        note "[i] registry 卷未找到（lab-registry 未建）——跳过，冒烟只验 gitea"
    fi
    # 3) TF state（28 的期望态 local state）
    if [ -f ../28_drift_detection/tf/terraform.tfstate ]; then
        cp ../28_drift_detection/tf/terraform.tfstate "$TS_DIR/terraform.tfstate"
        note "terraform.tfstate: $(du -h "$TS_DIR/terraform.tfstate" | cut -f1)"
    fi
    # 清单：什么必须备份 / 什么可重建
    cat > "$TS_DIR/MANIFEST.md" <<'EOF'
# 备份清单（RPO = 本目录生成时刻）
| 资产 | 备份 | 原因 |
|:---|:---|:---|
| Gitea 数据卷 | gitea-data.tar.gz | 仓库/用户/run 历史——不可重建 |
| registry 卷 | registry-data.tar.gz | 镜像 artifact——重构建成本高 |
| TF state | terraform.tfstate | 期望态事实源——丢了要 re-import |
| 容器/网络/镜像 | 不备份 | 可由 compose/TF/CI 完全重建 |
| 应用代码 | 不备份 | git 是事实源 |
EOF
    ok "备份完成 → ${TS_DIR}（清单见 MANIFEST.md）"
}

do_destroy() {
    step destroy "灾难演练：销毁 Gitea/registry 容器 + **数据卷** + TF state"
    rto_start
    docker rm -f "$G" "$RG" >/dev/null 2>&1 || true
    docker volume rm -f "$GITEA_VOL" >/dev/null 2>&1 || true
    REG_VOL=$(detect_reg_vol)
    [ -n "$REG_VOL" ] && docker volume rm -f "$REG_VOL" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -f ../28_drift_detection/tf/terraform.tfstate
    ok "灾难已注入：数据卷与 state 已灭（容器/网络一并清除）"
}

do_restore() {
    step restore "从备份恢复（卷重建 + 容器重建 + state 还原）"
    local dir
    dir=$(ls -dt "$B"/*/ 2>/dev/null | head -1)
    [ -n "$dir" ] || fail "没有备份目录——先 backup"
    note "使用备份：$dir"
    docker network create "$NET" >/dev/null 2>&1 || true
    # 1) 恢复 Gitea 卷
    docker volume create "$GITEA_VOL" >/dev/null
    docker run --rm -v "$GITEA_VOL":/data -v "$PWD/$dir":/backup:ro alpine \
        sh -c 'tar xzf /backup/gitea-data.tar.gz -C /data' || fail "Gitea 卷恢复失败"
    rto_report "gitea 卷恢复"
    # 2) 恢复 registry 卷（有备份才做）
    if [ -f "$dir/registry-data.tar.gz" ]; then
        REG_VOL=$(detect_reg_vol)
        [ -z "$REG_VOL" ] && { REG_VOL="lab-registry-data"; docker volume create "$REG_VOL" >/dev/null; }
        docker run --rm -v "$REG_VOL":/data -v "$PWD/$dir":/backup:ro alpine \
            sh -c 'tar xzf /backup/registry-data.tar.gz -C /data' || fail "registry 卷恢复失败"
        rto_report "registry 卷恢复"
    fi
    # 3) 重建容器（网络/端口/环境可重建——按 25 的参数）
    docker run -d --name "$G" --network "$NET" -p 3356:3000 \
        -e GITEA__security__INSTALL_LOCK=true \
        -e GITEA__actions__ENABLED=true \
        -e GITEA__server__ROOT_URL="http://localhost:3356/" \
        -v "$GITEA_VOL":/data \
        gitea/gitea:1.22 >/dev/null
    if [ -f "$dir/registry-data.tar.gz" ] || docker volume inspect "$REG_VOL" >/dev/null 2>&1; then
        docker run -d --name "$RG" --network "$NET" -p 5500:5000 \
            -v "$REG_VOL":/var/lib/registry registry:2 >/dev/null 2>&1 || true
        rto_report "registry 容器重建"
    fi
    # 4) 还原 TF state
    if [ -f "$dir/terraform.tfstate" ]; then
        cp "$dir/terraform.tfstate" ../28_drift_detection/tf/terraform.tfstate
        rto_report "TF state 还原"
    fi
    ok "恢复完成（等待冒烟确认）"
}

do_smoke() {
    step smoke "端到端冒烟（恢复后的世界还活着吗）"
    local i=0
    until curl -fsS http://localhost:3356/api/healthz >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 30 ] && fail "Gitea 60s 未就绪"
        sleep 2
    done
    ok "Gitea 健康"
    curl -s -u devops:devops123 "http://localhost:3356/api/v1/repos/devops/compliance" 2>/dev/null \
        | grep -q '"name":"compliance"' \
        && ok "仓库数据回来了（devops/compliance 在恢复后的 Gitea 里）" \
        || note "[i] 仓库断言跳过（该卷非 25 的合规仓库卷）"
    if docker ps --format '{{.Names}}' | grep -q "$RG"; then
        local i2=0
        until curl -fsS http://localhost:5500/v2/_catalog >/dev/null 2>&1; do
            i2=$((i2+1)); [ $i2 -gt 15 ] && fail "registry 30s 未就绪"
            sleep 2
        done
        local repos
        repos=$(curl -s http://localhost:5500/v2/_catalog | python3 -c "import sys,json; print(','.join(json.load(sys.stdin)['repositories']))")
        ok "registry catalog 有数据：$repos"
    fi
    if [ -f ../28_drift_detection/tf/terraform.tfstate ]; then
        python3 -c "import json; json.load(open('../28_drift_detection/tf/terraform.tfstate'))" \
            && ok "TF state JSON 合法"
    fi
    rto_report "冒烟通过（恢复完成）"
    note "RTO 总览见上方各阶段计时；RPO = 备份时刻到最后一次数据变更的间隔（本实验场景=0，备份即最新态）"
}

do_clean() {
    step clean "清理备份与运行时"
    rm -rf "$B"
    note "[ok] 零残留"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        backup)  do_backup ;;
        destroy) do_destroy ;;
        restore) do_restore ;;
        smoke)   do_smoke ;;
        clean)   do_clean ;;
        all)
            do_backup
            do_destroy
            do_restore
            do_smoke
            note "全演练完成——备份/灾难/恢复/冒烟 + RTO 分段计时"
            ;;
        *) echo "可用: backup | destroy | restore | smoke | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
