#!/usr/bin/env bash
# =============================================================================
# 09 · Chef + InSpec — 主演示脚本
#
# 环境形态：debian 容器（arm64 chef deb）里 chef-client --local-mode 收敛本机 nginx，
# 再用 InSpec 跑合规档案（5 条 control）。
# ⚠️ 官方 chef/chef 镜像（alpine+glibc ruby）在 arm64 上是坏的——本实验用 omnitruck
#    官方 deb 安装，并把装好的容器 commit 成本地镜像加速后续运行。
#
# ./chef_inspec.sh apply     起环境 → converge → 首次 InSpec（预期 4 过 1 失败）
# ./chef_inspec.sh fix       修复模板 → 再收敛 → InSpec 全绿（合规整改闭环）
# ./chef_inspec.sh clean     销毁容器（镜像缓存保留以加速复跑）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

C="lab09-chef"
IMG="lab09-chef:cached"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

wait_container() {
    local i=0
    until docker exec "$C" true >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 60 ] && { echo "    [!] 容器 60s 未就绪" >&2; exit 1; }
        sleep 1
    done
}

ensure_env() {
    step "env" "准备 Chef/InSpec 节点容器"
    # 确保"预修复"状态：删掉模板里的 server_tokens（第 5 条 control 将失败，供整改演示）
    LC_ALL=C sed -i '' '/server_tokens off;/d' cookbooks/webapp/templates/default/app.conf.erb

    if ! docker image inspect "$IMG" >/dev/null 2>&1; then
        note "首次运行：debian + omnitruck 官方 deb 安装 chef（arm64，含 inspec），约 2-3 分钟"
        docker rm -f "$C" >/dev/null 2>&1 || true
        docker run -d --name "$C" debian:12-slim sleep infinity >/dev/null
        docker exec "$C" bash -c "apt-get update -qq && apt-get install -y -qq curl ca-certificates libwww-perl >/dev/null && curl -sSL https://omnitruck.chef.io/install.sh | bash -s -- -P chef" >/dev/null
        docker commit "$C" "$IMG" >/dev/null
        note "[ok] 已缓存为本地镜像 ${IMG} （复跑秒级起环境）"
    fi
    docker rm -f "$C" >/dev/null 2>&1 || true
    # 模拟"预修复"失败的模板挂进去（从宿主机当前内容覆盖）
    docker run -d --name "$C" -p 28097:8080 \
        -v "$(pwd)/cookbooks:/cookbooks" \
        -v "$(pwd)/profiles:/profiles" \
        -w /cookbooks "$IMG" sleep infinity >/dev/null
    wait_container
}

do_apply() {
    step "converge" "chef-client --local-mode 收敛本机 nginx"
    docker exec -e CHEF_LICENSE=accept-silent -w /cookbooks "$C" chef-client --local-mode -o 'recipe[webapp]' 2>&1 \
        | grep -E "Chef Infra Client|converge|Running handlers|Chef Client finished" | tail -3 | LC_ALL=C sed 's/^/        /' || true

    step "inspec" "首次合规扫描（预期 4 通过 / 1 失败：server_tokens）"
    local rc=0
    docker exec -e CHEF_LICENSE=accept-silent -w /profiles "$C" /opt/chef/bin/inspec exec webapp --no-color --reporter cli 2>/dev/null | tail -14 | LC_ALL=C sed 's/^/        /' || rc=$?
    if [ $rc -ne 0 ]; then
        note "[检出] InSpec 退出码 $rc —— webapp-05 失败即'合规红旗'，这就是门禁信号"
    else
        note "[x] 预期失败未出现" >&2
    fi
}

do_fix() {
    step "fix" "整改：模板加 server_tokens off → 重收敛 → 重扫描（全绿）"
    LC_ALL=C grep -q "server_tokens off;" cookbooks/webapp/templates/default/app.conf.erb \
        || LC_ALL=C sed -i '' 's/server {/server {\n    server_tokens off;/' cookbooks/webapp/templates/default/app.conf.erb
    docker exec -e CHEF_LICENSE=accept-silent -w /cookbooks "$C" chef-client --local-mode -o 'recipe[webapp]' >/dev/null 2>&1
    docker exec -e CHEF_LICENSE=accept-silent -w /profiles "$C" /opt/chef/bin/inspec exec webapp --no-color --reporter cli 2>/dev/null | tail -3 | LC_ALL=C sed 's/^/        /'
    docker exec -e CHEF_LICENSE=accept-silent -w /profiles "$C" /opt/chef/bin/inspec exec webapp --no-color --reporter json-min 2>/dev/null | grep -o '"summary":[^,]*' | head -1 | LC_ALL=C sed 's/^/        /' || true
    note "[ok] 合规整改闭环：失败控件 → 改模板 → 收敛 → 全绿"
    note "宿主机验证：$(curl -s http://localhost:28097/healthz)"
}

do_clean() {
    step "clean" "销毁容器（镜像缓存保留）"
    docker rm -f "$C" >/dev/null 2>&1 || true
    ! docker ps -a --format '{{.Names}}' | grep -q "^$C$" && note "[ok] 容器零残留" || { note "[!] 残留" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        env)   ensure_env ;;
        apply) ensure_env; do_apply ;;
        fix)   do_fix ;;
        clean) do_clean ;;
        all)   ensure_env; do_apply; do_fix; do_clean ;;
        *) echo "可用: env | apply | fix | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
