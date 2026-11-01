#!/usr/bin/env bash
# semi/23_dr · 备份与容灾（gitlab-backup 全量 + 恢复演练 + RTO 计时）
# 用法：./dr.sh backup | restore | verify | status
#   backup  gitlab-backup create（含 registry/LFS 数据），归档 tar 到 data/
#   restore 毁掉现 gitlab 容器与卷 → 新容器恢复备份 → secrets 恢复 → 全链功能断言 + RTO
#   status  备份文件清单与体积
# ⚠️ restore 是破坏性演练：现 gitlab 数据卷会被删除重建（先跑 backup 才有得恢复）
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
BACKUP_DIR="$PWD/data"
CONTAINER_BACKUP_DIR="/var/opt/gitlab/backups"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 30 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

do_backup() {
    step backup "gitlab-backup create（数据卷内执行，含 LFS/registry 引用）"
    docker exec gitlab gitlab-backup create > /tmp/backup.log 2>&1 || true
    local tarname
    # GitLab 19.5 日志不再带引号：直接匹配 "Backup <ts>_<ver> is done."
    tarname=$(grep -oE "[0-9]{10}_[0-9]{4}_[0-9]{2}_[0-9]{2}_19\.[0-9]+\.[0-9]+_gitlab_backup\.tar" /tmp/backup.log | head -1)
    [ -n "$tarname" ] || tarname=$(grep -oE "'[^']*_gitlab_backup\.tar'" /tmp/backup.log | tr -d "'" | head -1)   # 旧版本兼容
    [ -n "$tarname" ] || { fail "备份 tar 未生成（见 /tmp/backup.log）"; exit 1; }
    pass "备份生成：$tarname"
    # secrets 单独拷出（gitlab-backup 不含它，恢复必需）
    docker cp gitlab:/etc/gitlab/gitlab-secrets.json "$BACKUP_DIR/gitlab-secrets.json" >/dev/null
    docker cp gitlab:/etc/gitlab/gitlab.rb "$BACKUP_DIR/gitlab.rb" >/dev/null
    pass "gitlab-secrets.json + gitlab.rb 已拷出（恢复必需）"
    # 归档到宿主 data/
    mkdir -p "$BACKUP_DIR"
    docker cp "gitlab:$CONTAINER_BACKUP_DIR/$tarname" "$BACKUP_DIR/" >/dev/null
    ls -lh "$BACKUP_DIR/$tarname" | awk '{print "  ", $9, $5}'
    echo "$tarname" > "$BACKUP_DIR/latest_backup_name"
}

do_restore() {
    local t0=$(date +%s)
    local tarname
    tarname=$(cat "$BACKUP_DIR/latest_backup_name" 2>/dev/null)
    [ -n "$tarname" ] || { fail "无备份可恢复（先跑 backup）"; exit 1; }
    step restore "毁掉现容器与卷 → 新容器 → 恢复备份（RTO 计时开始）"
    # 停止并删除容器（数据卷保留无用——恢复演练就是要从备份重建数据卷内容）
    docker compose -f ../01_gitlab_up/configs/docker-compose.yml down >/dev/null 2>&1 || true
    docker volume rm semi-gitlab_gitlab-data semi-gitlab_gitlab-config >/dev/null 2>&1 || true
    # 备份 tar 放进新数据卷
    docker volume create semi-gitlab_gitlab-data >/dev/null
    docker run --rm -v semi-gitlab_gitlab-data:/target -v "$BACKUP_DIR:/src" alpine:3 \
        sh -c "mkdir -p /target/backups /target/etc && cp /src/$tarname /target/backups/ && cp /src/gitlab-secrets.json /src/gitlab.rb /target/etc/ && chmod 777 /target/backups/$tarname" 2>/dev/null
    # 起新容器（compose 配置不变）
    docker compose -f ../01_gitlab_up/configs/docker-compose.yml up -d >/dev/null
    ./../01_gitlab_up/scripts/healthcheck.sh 2>&1 | tail -1
    # 恢复：backups 目录内执行 gitlab-backup restore（force=yes 免交互确认）
    # 经典坑：新卷初始化时扩展由非 gitlab 用户创建 → pg_restore 遇 DROP EXTENSION 中断
    # 官方修法：以应用身份 drop+create DB，让 gitlab 用户成为扩展属主，再 restore
    # 扩展属主是 gitlab-psql 角色（新 omnibus 超级用户）→ 以该角色 drop，restore 时由 gitlab 重建
    # 把扩展属主让给 gitlab（restore 时 DROP/CREATE EXTENSION 都以 gitlab 运行）
    docker exec gitlab gitlab-psql -U gitlab-psql -d gitlabhq_production \
        -c "ALTER EXTENSION pg_trgm OWNER TO gitlab; ALTER EXTENSION btree_gist OWNER TO gitlab; ALTER EXTENSION amcheck OWNER TO gitlab;" >/dev/null 2>&1 || true
    step restore2 "gitlab-backup restore（force=yes）"
    docker exec gitlab gitlab-backup restore force=yes > /tmp/restore.log 2>&1 ||
        { tail -5 /tmp/restore.log; fail "restore 失败"; exit 1; }
    # secrets 恢复（否则变量/LFS 解密全挂）；gitlab.rb 是 ro bind mount（config 从仓库来）不覆盖
    docker cp "$BACKUP_DIR/gitlab-secrets.json" gitlab:/etc/gitlab/gitlab-secrets.json >/dev/null
    docker exec gitlab gitlab-ctl reconfigure >/dev/null 2>&1
    docker exec gitlab gitlab-ctl restart >/dev/null 2>&1
    ./../01_gitlab_up/scripts/healthcheck.sh 2>&1 | tail -1
    local t1=$(date +%s)
    echo "[ok] RTO: $((t1 - t0)) 秒"
}

do_verify() {
    local FAILED=0
    step verify "恢复后功能断言（API/仓库/LFS 三层）"
    # 等待 PUMA 完全就绪（restart 后可能有 502 窗口）
    for _ in $(seq 1 24); do
        curl -sf --max-time 10 http://localhost:28200/users/sign_in -o /dev/null && break
        sleep 5
    done
    # ① API 层：项目与 MR 数据回来了
    local projects
    projects=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    [ -n "$projects" ] && pass "API：rtl-gcd 项目可见（id=${projects}）" ||
        { fail "rtl-gcd 项目不可见"; FAILED=1; }
    # ② git 层：clone 可用（凭据为 PAT——secrets 恢复后 token 仍有效）
    local tmp; tmp=$(mktemp -d)
    if git clone -q "http://root:$(cat "$TOKEN_FILE")@localhost:28200/semi/ip/design/rtl-gcd.git" "$tmp/repo" 2>/dev/null; then
        pass "git clone 正常（secrets 恢复 → token 链路有效）"
    else
        fail "git clone 失败"; FAILED=1
    fi
    # ③ LFS 层：SKIP_SMUDGE=0 拉 LFS 对象
    if (cd "$tmp/repo" && git lfs pull >/dev/null 2>&1) &&
       [ "$(stat -f%z "$tmp/repo/gds/fake.gds" 2>/dev/null || echo 0)" -gt 1000000 ]; then
        pass "LFS 对象可拉取（fake.gds 实体回来）"
    else
        fail "LFS 拉取失败"; FAILED=1
    fi
    rm -rf "$tmp"
    echo
    [ "$FAILED" = 0 ] && echo "[ok] 项目 23 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "备份文件"
    ls -lh "$BACKUP_DIR" 2>/dev/null | grep -E "backup|secrets" | sed 's/^/  /' || echo "  (无)"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        backup)  do_backup ;;
        restore) do_restore; do_verify ;;
        verify)  do_verify ;;
        status)  do_status ;;
        all)     do_backup; do_restore; do_verify ;;
        *) echo "用法: $0 backup | restore | verify | status | all" >&2; exit 1 ;;
    esac
}
main "$@"
