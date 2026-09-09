#!/usr/bin/env bash
# =============================================================================
# 10 · Puppet — 主演示脚本
#
# ⚠️ 探活结论（如实记录）：puppetserver-standalone 镜像在当前网络拉取失败
#    （registry 镜像 EOF，重试 2 次），且 puppetserver 为 JVM 重服务，agent 拉取
#    演示在本机模拟架构下代价过高。按 devops.md 预案降级为：
#    puppet/puppet-agent 单容器 + `puppet apply` —— 保住 DSL/资源模型/幂等的学习目标。
#    master/agent 拉模型的架构对照见 README §4.3。
#
# ./puppet_apply.sh apply       起节点容器 → puppet apply 收敛 nginx
# ./puppet_apply.sh idempotent  二次 apply（应 0 changes）
# ./puppet_apply.sh facts       facter/puppet resource 演示
# ./puppet_apply.sh clean       销毁容器
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

C="lab10-agent"
PUPPET="/opt/puppetlabs/bin/puppet"
MP="/etc/puppetlabs/code/environments/production/modules"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

wait_container() {
    local i=0
    until docker exec "$C" true >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 60 ] && { echo "    [!] 容器 60s 未就绪" >&2; exit 1; }
        sleep 1
    done
}

do_apply() {
    step "apply" "起 puppet-agent 节点容器（amd64 模拟）+ 挂载 manifests"
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker run -d --name "$C" -p 28098:8080 \
        --entrypoint /bin/bash \
        -v "$(pwd)/modules:/etc/puppetlabs/code/environments/production/modules:ro" \
        -v "$(pwd)/site.pp:/etc/puppetlabs/code/environments/production/manifests/site.pp:ro" \
        puppet/puppet-agent:latest -c 'sleep infinity' >/dev/null
    wait_container

    note "DSL 静态检查：puppet parser validate（语法门）"
    docker exec "$C" /opt/puppetlabs/bin/puppet parser validate \
        /etc/puppetlabs/code/environments/production/modules/webapp/manifests/init.pp \
        /etc/puppetlabs/code/environments/production/manifests/site.pp \
        && note "[ok] 语法通过"

    # 准备包索引（容器首启一次性；生产中这属于镜像层或 prepare 阶段）
    docker exec "$C" /usr/bin/apt-get update >/dev/null 2>&1 || true

    step "apply" "puppet apply site.pp（首次收敛，装 nginx + 渲染配置 + 启动）"
    docker exec "$C" "$PUPPET" apply --modulepath="$MP" \
        /etc/puppetlabs/code/environments/production/manifests/site.pp 2>&1 | tail -6 | LC_ALL=C sed 's/^/        /'

    note "curl 验证（容器内 127.0.0.1 + 宿主机 28098）"
    note "容器内 → $(docker exec "$C" /bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080; printf "GET /healthz HTTP/1.0\r\n\r\n" >&3; cat <&3' | tail -2 | head -1)"
    note "宿主机 → $(curl -s http://localhost:28098/healthz)"
}

do_idempotent() {
    step "idempotent" "二次 apply：应 0 changes"
    # --detailed-exitcodes：0=无变更（幂等），2=应用了变更，4=失败——与 terraform 同思想
    local rc=0
    out=$(docker exec "$C" "$PUPPET" apply --detailed-exitcodes --modulepath="$MP" \
        /etc/puppetlabs/code/environments/production/manifests/site.pp 2>&1) || rc=$?
    echo "$out" | LC_ALL=C sed 's/^/        /' | tail -2
    if [ "$rc" = "0" ]; then
        note "[ok] exit=0 无任何变更，幂等达成"
    elif [ "$rc" = "2" ]; then
        note "[x] exit=2 仍有变更" >&2; exit 1
    else
        note "[x] 失败 exit=$rc" >&2; exit 1
    fi
}

do_facts() {
    step "facts" "facter 事实与 puppet resource 反向查询"
    docker exec "$C" /opt/puppetlabs/bin/facter os.family os.release.major 2>/dev/null | LC_ALL=C sed 's/^/        /'
    docker exec "$C" "$PUPPET" resource package nginx 2>/dev/null | LC_ALL=C sed 's/^/        /'
    note "[ok] resource 命令：从实际状态反向生成资源声明（对比 pilot：'现状导出'）"
}

do_clean() {
    step "clean" "销毁节点容器"
    docker rm -f "$C" >/dev/null 2>&1 || true
    ! docker ps -a --format '{{.Names}}' | grep -q "^$C$" && note "[ok] 零残留" || { note "[!] 残留" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)      do_apply ;;
        idempotent) do_idempotent ;;
        facts)      do_facts ;;
        clean)      do_clean ;;
        all)        do_apply; do_idempotent; do_facts; do_clean ;;
        *) echo "可用: apply | idempotent | facts | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
