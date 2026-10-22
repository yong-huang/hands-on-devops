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

do_apply() {
    step "apply" "拉起靶场：nginx + registry + minio + gitea"
    $TF init -input=false
    $TF apply -auto-approve -input=false

    wait_http "http://localhost:28085/" "nginx 应用"
    wait_http "http://localhost:5500/v2/" "私有 registry"
    wait_http "http://localhost:9100/minio/health/live" "MinIO"
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
    $TF destroy -auto-approve -input=false || true
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep '^lab-' || true)
    if [ -z "$leftover" ] && ! docker volume ls --format '{{.Name}}' | grep -q '^lab-' \
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
