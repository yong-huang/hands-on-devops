#!/usr/bin/env bash
# =============================================================================
# 03 · 状态管理深潜 — 主演示脚本
#
# 前置：本机 docker + terraform（MinIO/mc 镜像由脚本按需拉起）
# 生命周期：backend → apply → stateops(mv/rm/import) → sensitive → lock(互斥) → clean
# 用法：
#   ./tf_state.sh            # 依次执行全部
#   ./tf_state.sh lock       # 只演示锁互斥（两人同时 apply + force-unlock 恢复）
# =============================================================================
set -euo pipefail
export LC_ALL=C  # macOS sed 处理 UTF-8 注释文件会报 illegal byte sequence
cd "$(dirname "$0")"

. "../../scripts/tfrc.sh"
. "../../scripts/docker-env.sh"

TF="terraform -chdir=configs"
WORKER_A="tmp/worker-a"
WORKER_B="tmp/worker-b"
LOCK_ID="11111111-2222-3333-4444-555555555555"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# 在 MinIO 里确保 bucket 存在（mc 容器即用即弃，经 host.docker.internal 回连宿主端口）
ensure_bucket() {
    docker run --rm --network tf03-net --entrypoint sh minio/mc -c \
        "mc alias set m http://tf03-minio:9000 minioadmin minioadmin >/dev/null && mc mb -p m/tfstate" \
        >/dev/null 2>&1 || true
}

# 把 configs/*.tf 复制成一个"工程师工作目录"（各自 init，共享同一后端）
make_worker() {
    local d="$1"
    rm -rf "$d" && mkdir -p "$d"
    cp configs/*.tf "$d/"
    ( cd "$d" && TF_IN_AUTOMATION=1 terraform init -input=false >/dev/null )
}

do_backend() {
    step "backend" "启动 MinIO（S3 兼容）并初始化远端后端"
    docker network create tf03-net >/dev/null 2>&1 || true
    docker rm -f tf03-minio >/dev/null 2>&1 || true
    docker run -d --name tf03-minio --network tf03-net -p 9000:9000 -p 9001:9001 \
        -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
        minio/minio server /data --console-address ":9001" >/dev/null
    local i=0
    until curl -fsS http://localhost:9000/minio/health/live >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 30 ] && { echo "    [!] MinIO 30s 未就绪" >&2; exit 1; }
        sleep 1
    done
    ensure_bucket
    # 清掉上次失败运行可能遗留的本地对象（被 state rm 遗忘的资源不在 destroy 范围内）
    docker rm -f tf03-keeper >/dev/null 2>&1 || true
    docker volume rm -f tf03-db tf03-orphan >/dev/null 2>&1 || true
    # 清掉上一次运行遗留的远端 state，保证实验可重复（幂等起点）
    docker run --rm --network tf03-net --entrypoint sh minio/mc -c \
        "mc alias set m http://tf03-minio:9000 minioadmin minioadmin >/dev/null && mc rm -r --force --dangerous m/tfstate/lab03" >/dev/null 2>&1 || true
    # 配置被上一轮演示污染时快速失败（orphan 块应由脚本追加并在结束时撤掉）
    if grep -q 'docker_volume" "orphan"' configs/main.tf; then
        echo "    [!] configs/main.tf 含 orphan 残块，自动清除"; 
        sed -i '' '/手动建又被 import 收编的/,$d' configs/main.tf
    fi
    # 本地 .terraform 缓存可能存有旧 state 快照，不清掉会"复活"已销毁的资源
    rm -rf configs/.terraform
    $TF init -input=false
    note "state 已写入 MinIO：bucket=tfstate key=lab03/terraform.tfstate"
    docker exec tf03-minio sh -c 'ls -la /data/tfstate/lab03/' 2>/dev/null | sed 's/^/        /' || true
}

do_apply() {
    step "apply" "创建 2 个资源，state 落在 MinIO"
    $TF apply -auto-approve -input=false
    $TF state list | sed 's/^/        /'
}

do_stateops() {
    step "stateops" "state mv / rm / import 三板斧"
    note "① 改名：配置里 docker_volume.db → database（sed），state 用 mv 追上"
    sed -i '' -e 's/resource "docker_volume" "db"/resource "docker_volume" "database"/' \
         -e 's/docker_volume\.db\.name/docker_volume.database.name/' configs/main.tf
    $TF state mv docker_volume.db docker_volume.database
    local rc=0
    $TF plan -detailed-exitcode -input=false >/dev/null 2>&1 || rc=$?
    note "   plan exit=${rc} （0 = 纯改名，没有销毁重建）"
    note "   演示完自动改回（配置自愈，保持实验可重复）"
    sed -i '' -e 's/resource "docker_volume" "database"/resource "docker_volume" "db"/' \
         -e 's/docker_volume\.database\.name/docker_volume.db.name/' configs/main.tf
    $TF state mv docker_volume.database docker_volume.db

    note "② 遗忘：state rm 后 plan 要求'创建'（TF 忘了它，但卷还活着）"
    $TF state rm docker_container.keeper
    $TF plan | grep -E "docker_container.keeper|1 to add" | head -3 | sed 's/^/        /' || true
    note "   卷 tf03-db 仍在：$(docker volume ls --format '{{.Name}}' | grep tf03-db)"

    note "③ 收编：手动建的卷 import 进 state，从此受 TF 管"
    docker volume rm -f tf03-orphan >/dev/null 2>&1 || true
    docker volume create tf03-orphan >/dev/null
    grep -q 'docker_volume" "orphan"' configs/main.tf || cat >> configs/main.tf <<'EOF'

# 手动建又被 import 收编的"野生卷"
resource "docker_volume" "orphan" {
  name = "tf03-orphan"
}
EOF
    $TF import docker_volume.orphan tf03-orphan
    $TF plan -detailed-exitcode -target=docker_volume.orphan -input=false >/dev/null 2>&1 || rc=$?
    note "   plan exit=${rc} （0 = import 后 TF 认为现状已符合期望；-target 只看被收编的卷）"
    note "   演示完收回：state rm + 撤配置 + 删卷（配置自愈）"
    $TF state rm docker_volume.orphan
    sed -i '' '/手动建又被 import 收编的/,$d' configs/main.tf
    docker volume rm -f tf03-orphan >/dev/null
}

do_sensitive() {
    step "sensitive" "输出打码了，state 里呢？——当场 grep"
    note "终端输出（sensitive 生效，值为 <sensitive>）"
    $TF output token_masked | sed 's/^/        /' || true
    note "直接从 MinIO 拉原始 state 看（mc cat）"
    docker run --rm --network tf03-net --entrypoint sh minio/mc -c \
        "mc alias set m http://tf03-minio:9000 minioadmin minioadmin >/dev/null && mc cat m/tfstate/lab03/terraform.tfstate" \
        | grep -o "super-secret-token-do-not-commit" | head -1 | sed 's/^/        state 明文包含: /' \
        || note "（未找到——检查 state 内容）"
    note "[结论] sensitive 只是 UI 层打码；state 文件永远明文 → 后端访问控制才是安全边界"
}

do_lock() {
    step "lock" "锁互斥：远端 state 的并发保护"
    make_worker "$WORKER_A"
    make_worker "$WORKER_B"

    note "① 确定性演示：手工放置锁对象（.tflock，TF 的锁就是后端里的一个对象）"
    LOCKJSON="{\"ID\":\"$LOCK_ID\",\"Operation\":\"OperationTypeApply\",\"Info\":\"\",\"Who\":\"someone-else@$(hostname)\",\"Version\":\"1.15.8\",\"Created\":\"$(date -u +%FT%TZ)\"}"
    printf '%s' "$LOCKJSON" | docker run -i --rm --network tf03-net --entrypoint sh minio/mc -c \
        "mc alias set m http://tf03-minio:9000 minioadmin minioadmin >/dev/null && mc pipe m/tfstate/lab03/terraform.tfstate.tflock" || true
    docker run --rm --network tf03-net --entrypoint sh minio/mc -c \
        "mc alias set m http://tf03-minio:9000 minioadmin minioadmin >/dev/null && mc stat m/tfstate/lab03/terraform.tfstate.tflock" \
        | grep -E "Name|Size" | head -2 | sed 's/^/        锁对象: /'
    local rc=0
    ( cd "$WORKER_B" && terraform plan -input=false -lock-timeout=3s ) >/tmp/lab03_lock2.log 2>&1 || rc=$?
    if grep -q "Error acquiring the state lock" /tmp/lab03_lock2.log; then
        note "[检出] worker-B 的 plan 被拒绝：Error acquiring the state lock"
        grep -E "Lock Info|ID:|Operation:|Who:" /tmp/lab03_lock2.log | head -4 | sed 's/^/        /'
    else
        note "[!] 未检出锁（exit=${rc}）——见 /tmp/lab03_lock2.log" >&2
    fi
    note "② 恢复：锁的持有人不在了（进程死了）→ force-unlock 强制解锁"
    ( cd "$WORKER_B" && terraform force-unlock -force "$LOCK_ID" ) | grep -vE "^$|Warning|Deprecated|instead|╵|╷|│ " | sed 's/^/        /' || true

    note "③ 加分演示：两目录同时 apply（真实竞争）"
    ( cd "$WORKER_A" && terraform apply -auto-approve -replace=docker_container.keeper -input=false >/dev/null 2>&1 ) &
    local apid=$!
    sleep 0.3
    ( cd "$WORKER_B" && terraform apply -auto-approve -input=false ) >/tmp/lab03_lock.log 2>&1 || true
    wait $apid || true
    if grep -qE "Error acquiring the state lock|already in use by container" /tmp/lab03_lock.log; then
        grep -oE "Error acquiring the state lock|already in use by container" /tmp/lab03_lock.log | head -1 | sed 's/^/        [检出] worker-B 撞车: /'
        note "        无论撞在锁上还是撞在资源名上——'两人同时改同一份基础设施'必然出事，这就是锁存在的理由"
    else
        note "（竞速未撞上——锁演示以①②的确定性结果为准）"
    fi
}

do_clean() {
    step "clean" "销毁资源、MinIO、工作目录，全清"
    $TF destroy -auto-approve -input=false || true
    # state rm 遗忘掉的资源 TF 不会销毁——手工兜底（这正是 state rm 的含义）
    docker rm -f tf03-keeper >/dev/null 2>&1 || true
    docker volume rm -f tf03-db tf03-orphan >/dev/null 2>&1 || true
    docker rm -f tf03-minio >/dev/null 2>&1 || true
    docker network rm tf03-net >/dev/null 2>&1 || true
    rm -f /tmp/lab03_lock*.log
    rm -rf tmp
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep '^tf03' || true)
    [ -z "$leftover" ] && docker volume ls --format '{{.Name}}' | grep -q '^tf03' && leftover="tf03卷" || true
    [ -z "$leftover" ] && note "[ok] 零残留" || { note "[!] 残留：$leftover" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        backend)   do_backend ;;
        apply)     do_apply ;;
        stateops)  do_stateops ;;
        sensitive) do_sensitive ;;
        lock)      do_lock ;;
        clean)     do_clean ;;
        all)       do_backend; do_apply; do_stateops; do_sensitive; do_lock; do_clean ;;
        *) echo "可用: backend | apply | stateops | sensitive | lock | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
