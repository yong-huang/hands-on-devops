#!/usr/bin/env bash
# =============================================================================
# 04 · 缓存与构建加速 — 主演示脚本
#
# 完整生命周期：cold → warm → miss → clean
# 用法：
#   ./cache_accel.sh cold    # 冷跑：--no-cache 全量构建，计时 3 次取中位数
#   ./cache_accel.sh warm    # 热跑：命中 Docker 层缓存，计时 3 次取中位数
#   ./cache_accel.sh miss    # 改 deps.lock 触发缓存 miss（取证）
#   ./cache_accel.sh clean   # 清构建缓存与临时文件
#   ./cache_accel.sh         # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

LOGS=".logs"
DOCKER_DIR="docker"
IMAGE="cache-demo"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

ensure_ready() {
    command -v docker >/dev/null || { echo "需要 Docker" >&2; exit 1; }
    docker info >/dev/null 2>&1 || { echo "Docker daemon 未运行" >&2; exit 1; }
    mkdir -p "$LOGS" "$DOCKER_DIR/src"
}

# 跑一次构建并返回耗时（秒）
time_build() {
    local mode="${1:-warm}"  # cold = --no-cache
    local extra=""
    [ "$mode" = "cold" ] && extra="--no-cache"
    local start end
    start=$(date +%s)
    docker build $extra -t "$IMAGE" "$DOCKER_DIR" >/dev/null 2>&1
    end=$(date +%s)
    echo $((end - start))
}

# 计时 3 次取中位数（诊断行走 stderr，stdout 只输出中位数数值）
median_of_3() {
    local mode="$1" log="$2"
    local t1 t2 t3
    t1=$(time_build "$mode")
    t2=$(time_build "$mode")
    t3=$(time_build "$mode")
    local med
    med=$(printf '%s\n%s\n%s\n' "$t1" "$t2" "$t3" | sort -n | sed -n '2p')
    echo "        $mode 3 次: ${t1}s ${t2}s ${t3}s → 中位数 ${med}s" >> "$LOGS/$log"
    echo "$med"
}

do_cold() {
    step "cold" "冷跑：--no-cache 全量构建（依赖层 sleep 6s）"
    ensure_ready
    docker rmi "$IMAGE" >/dev/null 2>&1 || true
    local med
    med=$(median_of_3 cold cold-timing.log)
    tail -1 "$LOGS/cold-timing.log" | sed 's/^/        /'
}

do_warm() {
    step "warm" "热跑：命中 Docker 层缓存"
    ensure_ready
    # 先冷跑一次确保层缓存存在
    docker build -t "$IMAGE" "$DOCKER_DIR" >/dev/null 2>&1
    local med
    med=$(median_of_3 warm warm-timing.log)
    tail -1 "$LOGS/warm-timing.log" | sed 's/^/        /'
    # 断言提速
    local cold_med
    cold_med=$(grep '中位数' "$LOGS/cold-timing.log" | tail -1 | grep -oE '[0-9]+s' | tr -d 's' | tail -1)
    if [ -n "$cold_med" ] && [ "$cold_med" -gt 0 ]; then
        local pct=$(( (cold_med - med) * 100 / cold_med ))
        note "提速：${cold_med}s → ${med}s（节省 ${pct}%）"
        [ "${pct}" -ge 50 ] \
            || { echo "    [!] 提速 ${pct}% < 50%（cold=${cold_med}s warm=${med}s）" >&2; exit 1; }
        note "[ok] 热跑提速 ≥50%（${pct}%）"
    else
        note "[i] 无 cold 基线，跳过提速断言（先跑 cold 段）"
    fi
}

do_miss() {
    step "miss" "改 deps.lock 触发缓存 miss（取证）"
    ensure_ready
    # 确保当前有缓存（先跑一次热跑）
    docker build -t "$IMAGE" "$DOCKER_DIR" >/dev/null 2>&1
    # 获取当前 deps.lock 的层 ID
    local before_layer
    before_layer=$(docker build --no-cache --progress=plain "$DOCKER_DIR" 2>&1 \
        | grep "RUN sleep" | head -1 | grep -oE 'sha256:[a-f0-9]{12}' || true)
    # 改 deps.lock → COPY 层的 checksum 变 → RUN 层缓存 miss
    echo "version 2.0-changed" > "$DOCKER_DIR/deps.lock"
    note "deps.lock 已改为 version 2.0-changed，重新构建："
    local out
    out=$(docker build --progress=plain "$DOCKER_DIR" 2>&1)
    echo "$out" | grep -qE "RUN sleep" \
        && ! echo "$out" | grep -qE "CACHED \[.*RUN sleep" \
        || { echo "    [!] RUN sleep 层竟然命中缓存（应 miss）" >&2; exit 1; }
    note "[ok] deps.lock 变更 → COPY 层 checksum 变 → RUN sleep 层缓存 miss（依赖重装）"
    # 还原 deps.lock
    echo "version 1.0" > "$DOCKER_DIR/deps.lock"
    note "deps.lock 已还原"
}

do_clean() {
    step "clean" "清构建缓存与临时文件"
    docker rmi "$IMAGE" >/dev/null 2>&1 || true
    rm -rf "$LOGS"
    note "[ok] $IMAGE 镜像与日志已清；deps.lock 还原为 version 1.0"
    echo "version 1.0" > "$DOCKER_DIR/deps.lock"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        cold)  do_cold ;;
        warm)  do_warm ;;
        miss)  do_miss ;;
        clean) do_clean ;;
        all)   do_cold; do_warm; do_miss; do_clean ;;
        *) echo "可用: cold | warm | miss | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
