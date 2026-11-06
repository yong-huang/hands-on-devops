#!/usr/bin/env bash
# =============================================================================
# 05 · 靶场环境 — 主演示脚本（整系列的基座，root Makefile 的 lab-up/down 就是它）
#
# ./lab_foundation.sh apply    拉起靶场（幂等，可反复执行）
# ./lab_foundation.sh observe  服务健康检查 + endpoints 清单
# ./lab_foundation.sh clean    terraform destroy 全清
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/tfrc.sh"
. "../../scripts/docker-env.sh"

TF="terraform -chdir=configs"

# 自家 ObjStor (Rust S3 兼容存储, github.com/yong-huang/objstor)——
# minio 镜像在受限网络全线 denied 时的回退后端 (宿主进程模式, 长驻 9100)
OBJSTOR_SRC="$(cd "$PWD/../../.." && pwd)/objstor"
OBJSTOR_DATA="$PWD/objstor-data"
OBJSTOR_PID_FILE="$OBJSTOR_DATA/objstor.pid"
OBJSTOR_LOG="$OBJSTOR_DATA/objstor.log"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

wait_http() { # wait_http <url> <名称> [ tries ]
    local url="$1" name="$2" tries="${3:-30}" i=0
    until curl -fsS -o /dev/null "$url" 2>/dev/null; do
        i=$((i+1)); [ $i -gt "$tries" ] && { echo "    [!] $name ($url) ${tries}0s 未就绪" >&2; return 1; }
        sleep 2
    done
    echo "    [ok] $name 就绪"
}

start_objstor() { # 长驻 S3 服务: 宿主进程模式, 监听 9100 (与 lab-minio 同端口同凭据)
    local bin="$OBJSTOR_SRC/target/release/objstor"
    [ -x "$bin" ] || { echo "    构建 ObjStor release 二进制 (首次约 1 分钟)..."; ( cd "$OBJSTOR_SRC" && cargo build --release >/dev/null ); }
    [ -x "$bin" ] || { echo "    [!] ObjStor 构建失败 (需要 Rust 工具链)" >&2; exit 1; }
    # 清掉上次遗留的进程
    if [ -f "$OBJSTOR_PID_FILE" ]; then kill "$(cat "$OBJSTOR_PID_FILE")" 2>/dev/null || true; rm -f "$OBJSTOR_PID_FILE"; fi
    rm -rf "$OBJSTOR_DATA" && mkdir -p "$OBJSTOR_DATA/data/config" "$OBJSTOR_DATA/logs"
    OBJSTOR_DATA="$OBJSTOR_DATA" python3 - <<'PY'
import json, os
data = os.environ["OBJSTOR_DATA"]
cfg = {
    "server": {"host": "0.0.0.0", "port": 9100, "s3_port": 9100, "enable_tls": False,
               "tls_cert": "", "tls_key": "", "max_request_size": 5368709120,
               "log_level": "info", "log_dir": "./logs"},
    "storage": {"data_dir": os.path.join(data, "data"),
                "pools": [{"id": "pool-001", "path": os.path.join(data, "pool"),
                           "capacity": 107374182400, "max_objects": 1000000,
                           "quota_enabled": False, "tier": "hot"}],
                "scheduler": {"strategy": "least_loaded", "rebalance_threshold": 0.2}},
    "ai": {"enabled": False, "api_endpoint": "", "api_key": "", "model": "",
           "max_tokens": 1024, "timeout_secs": 15, "auto_tag": False}
}
open(os.path.join(data, "data", "config", "objstor.json"), "w").write(json.dumps(cfg, indent=2))
PY
    ( cd "$OBJSTOR_DATA" && OBJSTOR_DATA_DIR="$OBJSTOR_DATA" "$bin" >> "$OBJSTOR_LOG" 2>&1 & echo $! > "$OBJSTOR_PID_FILE" )
    sleep 1
}

stop_objstor() {
    if [ -f "$OBJSTOR_PID_FILE" ]; then
        kill "$(cat "$OBJSTOR_PID_FILE")" 2>/dev/null || true
        rm -f "$OBJSTOR_PID_FILE"
    fi
    rm -rf "$OBJSTOR_DATA"
}

do_apply() {
    step "apply" "拉起靶场：nginx + registry + minio + gitea"
    # minio 镜像拉取探测: denied (Docker Hub 限流+DNS 污染) 时回退 ObjStor
    local minio_fallback=0
    if ! docker pull minio/minio:latest >/dev/null 2>&1; then
        minio_fallback=1
        echo "    [!] minio/minio 拉取失败 —— 回退自家 ObjStor (宿主进程模式, 长驻 9100)"
        start_objstor
    fi
    $TF init -input=false
    if [ "$minio_fallback" = 1 ]; then
        $TF apply -auto-approve -input=false -var enable_minio=false
    else
        $TF apply -auto-approve -input=false
    fi

    wait_http "http://localhost:28085/" "nginx 应用"
    wait_http "http://localhost:5500/v2/" "私有 registry"
    if [ "$minio_fallback" = 1 ]; then
        wait_http "http://localhost:9100/health" "MinIO (ObjStor 回退)"
        # 种下与下游实验一致的 minioadmin 凭据 (已存在则忽略)
        curl -sf -X POST http://localhost:9100/api/v1/access-keys \
            -H "Content-Type: application/json" \
            -d '{"access_key_id":"minioadmin","secret_key":"minioadmin"}' >/dev/null 2>&1 \
            || note "[=] minioadmin 凭据已存在"
    else
        wait_http "http://localhost:9100/minio/health/live" "MinIO"
    fi
    wait_http "http://localhost:3300/api/healthz" "Gitea"

    step "apply" "创建 Gitea 管理员（后续实验的代码源入口）"
    # 幂等：用户已存在时 gitea 返回非零，吞掉即可。
    # 坑：docker exec 默认 root，而 gitea 拒绝以 root 跑 CLI——必须 -u 1000（镜像内 git 用户）
    docker exec -u 1000 lab-gitea gitea admin user create \
        --username devops --password devops123 --email devops@lab.local --admin \
        >/dev/null 2>&1 \
        && note "[ok] 管理员 devops 创建成功" \
        || note "[=] 管理员已存在"
}

do_observe() {
    step "observe" "靶场健康检查 + 服务清单"
    docker ps --filter "name=lab-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed 's/^/        /'
    note "endpoints（terraform output）："
    $TF output -json endpoints | jq -r 'to_entries[] | "        \(.key): \(.value | if type=="object" then (.|tojson) else . end)"'
}

do_clean() {
    step "clean" "销毁靶场（destroy 全清，数据卷一并回收）"
    # 先强制移除容器: 卷的 in_use 竞态 (容器 Terminating 未释放挂载) 会让
    # destroy 卡 30s 超时 (lab 03 同款竞态, 实测踩过) —— 容器一走, 卷即可删
    docker stop lab-nginx lab-registry lab-minio lab-gitea 2>/dev/null || true
    docker rm -f lab-nginx lab-registry lab-minio lab-gitea 2>/dev/null || true
    $TF destroy -auto-approve -input=false || $TF destroy -auto-approve -input=false || true
    # OrbStack 卷挂载释放有滞后: 兜底强删本靶场的卷与网络 (挂载未释放时失败,
    # 留待下次 clean 兜底重删)
    sleep 15   # OrbStack 卷挂载释放滞后实测可超 30s, 给足时间再兜底强删
    docker volume rm -f lab-registry-data lab-minio-data lab-gitea-data 2>/dev/null || true
    docker network rm devops-lab 2>/dev/null || true
    # ObjStor 回退模式的宿主进程与数据目录一并回收（与 MinIO 卷的销毁对称）
    stop_objstor
    # 残留检查只看本靶场的资源名 —— lab-redis/lab-etcd 等是其他项目的
    # lab-infra 容器, 名字同以 lab- 开头但与本靶场无关
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep -E '^lab-(nginx|registry|minio|gitea)' || true)
    if [ -z "$leftover" ] && ! docker volume ls --format '{{.Name}}' | grep -qE '^lab-(registry|minio|gitea)-data' \
        && ! docker network ls --format '{{.Name}}' | grep -q '^devops-lab$'; then
        note "[ok] 零残留，回到实验前状态"
    else
        note "[!] 残留：${leftover:-卷或网络}" >&2
        return 1
    fi
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)   do_apply ;;
        observe) do_observe ;;
        clean)   do_clean ;;
        all)     do_apply; do_observe; do_clean ;;
        *) echo "可用: apply | observe | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
