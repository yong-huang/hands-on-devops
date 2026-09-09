#!/usr/bin/env bash
# =============================================================================
# 01 · TF Docker Provider — 主演示脚本
#
# 完整生命周期：init/apply → observe → drift(注入漂移+检出+回正) → clean
# 用法：
#   ./tf_docker_provider.sh apply    # 创建全套资源
#   ./tf_docker_provider.sh observe  # 查看 state 与实际容器
#   ./tf_docker_provider.sh drift    # 手动 stop 容器 → plan 检出 → apply 回正
#   ./tf_docker_provider.sh clean    # destroy 全清，无残留
#   ./tf_docker_provider.sh          # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# provider 用仓库自带离线镜像（GitHub Releases 在部分网络不可达，见 scripts/tfrc.sh）
. "../../scripts/tfrc.sh"
# Go 客户端不认 docker context，显式选一个响应正常的 socket（见 scripts/docker-env.sh）
. "../../scripts/docker-env.sh"

TF="terraform -chdir=configs"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# 容器健康等待：轮询 docker inspect，最多 30s（不裸 sleep）
wait_healthy() {
    local name="$1" i=0
    until [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null)" = "healthy" ]; do
        i=$((i+1)); [ $i -gt 30 ] && { echo "    [!] $name 30s 未 healthy"; return 1; }
        sleep 1
    done
    echo "    [ok] $name 已 healthy"
}

do_init() {
    step "init" "拉取 provider 并锁定版本（生成 .terraform.lock.hcl）"
    $TF init -input=false
}

do_apply() {
    step "apply" "创建 网络+卷+播种容器+nginx（依赖图自动排序）"
    $TF apply -auto-approve -input=false
    local url
    url=$($TF output -raw app_url)
    note "curl 验证首页（应命中 TF 播种的标题；若命中别的服务说明端口被占）"
    local body
    body=$(curl -fsS "$url")
    echo "        $body"
    grep -q "tf01\|served by terraform" <<<"$body" || {
        echo "    [x] 命中了别的服务——默认端口 28080 被占用？用 -var host_port=其他端口 换端口" >&2; exit 1; }
    wait_healthy tf01-nginx || true
}

do_observe() {
    step "observe" "TF 视角 vs Docker 视角，同一批资源"
    note "terraform state list —— state 记账本里的资源"
    $TF state list
    note "docker ps 对照（名字应一一对应）"
    docker ps --filter "name=tf01" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    note "state show 看'期望态'详情（截取关键行）"
    $TF state show docker_container.app | grep -E "^(resource|  name|  image|  start)" || true
    note "第二次 apply 应为 No changes（幂等性验证）"
    $TF apply -auto-approve -input=false -refresh-only >/dev/null
    $TF plan -detailed-exitcode -input=false >/dev/null && note "exit=0：无漂移，plan 为空" \
        || note "exit=2：plan 有变更（不应出现，除非上一命令未刷新）"
}

do_drift() {
    step "drift" "手动 docker stop 注入漂移 → plan 检出 → apply 回正"
    note "模拟'有人手动动了环境'：docker stop tf01-nginx"
    docker stop tf01-nginx >/dev/null
    docker ps --filter "name=tf01-nginx" --format "{{.Names}}" | grep . \
        && note "容器仍在运行（异常）" || note "容器已停（实际状态偏离期望态：running）"
    note "terraform plan 用 -detailed-exitcode：有变更时 exit=2（脚本据此不中断）"
    local rc=0
    $TF plan -detailed-exitcode -input=false || rc=$?
    if [ "$rc" = "2" ]; then
        note "[检出] plan 检出漂移（above: 1 to recreate/replace 或必须变更）—— 这就是'期望态 vs 实际态'的 diff"
    else
        note "[未检出] exit=$rc —— 检查 provider refresh 行为" >&2
    fi
    note "apply 让实际状态收敛回期望态（自愈）"
    $TF apply -auto-approve -input=false
    wait_healthy tf01-nginx || true
    curl -fsS http://localhost:28080/ | grep -q "served by terraform" \
        && note "[ok] 服务已恢复（内容来自 TF 播种）" || { note "[x] 恢复后内容不对" >&2; exit 1; }
}

do_clean() {
    step "clean" "destroy 全清 + 残留断言"
    $TF destroy -auto-approve -input=false
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep '^tf01' || true)
    if [ -z "$leftover" ] && ! docker network ls --format '{{.Name}}' | grep -q '^tf01' \
        && ! docker volume ls --format '{{.Name}}' | grep -q '^tf01'; then
        note "[ok] 容器/网络/卷零残留，回到实验前状态"
    else
        note "[!] 有残留：${leftover:-网络或卷}" >&2
        return 1
    fi
}

main() {
    local target="${1:-all}"
    case "${target}" in
        init)    do_init ;;
        apply)   do_init; do_apply ;;
        observe) do_observe ;;
        drift)   do_drift ;;
        clean)   do_clean ;;
        all)     do_init; do_apply; do_observe; do_drift; do_clean ;;
        *) echo "可用: init | apply | observe | drift | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
