#!/usr/bin/env bash
# =============================================================================
# 06 · Ansible 深水区 — 主演示脚本
#
# 前置：靶场在跑（make lab-up）；ansible + community.docker 集合已安装
# ./ansible_role_vault.sh apply     首次部署（changed>0）
# ./ansible_role_vault.sh idempotent 二次执行（应 changed=0）
# ./ansible_role_vault.sh drift     手动改容器内配置 → 重跑 → 自愈
# ./ansible_role_vault.sh vault     vault 加密取证
# ./ansible_role_vault.sh clean     还原实验痕迹
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
# 注意：这里不能 export LC_ALL=C（macOS 上会破坏 sed 处理 UTF-8 的能力之外的另一些工具）——
# Ansible 强制要求 UTF-8 locale，LC_ALL=C 会直接报 "requires the locale encoding to be UTF-8"

. "../../scripts/docker-env.sh"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

ensure_prereq() {
    [ -f tmp/vault-pass ] || { mkdir -p tmp; echo "devops-vault" > tmp/vault-pass; }
    # 首次运行把 vault.yml 加密（之后就是密文，可安全提交）
    if grep -q "vault_deploy_token" group_vars/all/vault.yml 2>/dev/null; then
        ansible-vault encrypt group_vars/all/vault.yml >/dev/null 2>&1
        note "[ok] vault.yml 已加密（密文入库，口令在 tmp/vault-pass）"
    fi
}

do_apply() {
    step "apply" "动态清单发现 → role 首次部署（预期 changed>0）"
    ansible-inventory inventory/docker.docker.yml --graph 2>/dev/null | LC_ALL=C sed 's/^/        /' || true
    ansible-playbook playbook.yml
    note "容器内取证：healthz 端点带 vault 渲染的 token"
    docker exec lab-nginx curl -s http://localhost/healthz 2>/dev/null \
        || docker exec lab-nginx wget -qO- http://localhost/healthz
}

do_idempotent() {
    step "idempotent" "立即重跑：应当 changed=0（幂等是 Ansible 的及格线）"
    local out
    out=$(ansible-playbook playbook.yml 2>/dev/null)
    tail -12 <<<"$out" | LC_ALL=C sed 's/^/        /'
    grep -q "changed=0" <<<"$out" && note "[ok] changed=0，幂等达成" || { note "[x] 仍有 changed" >&2; exit 1; }
}

do_drift() {
    step "drift" "手动破坏容器内配置 → 重跑 playbook → 自愈"
    docker exec lab-nginx sh -c "echo '# 有人在容器里手改了配置' > /etc/nginx/conf.d/site.conf"
    docker exec lab-nginx grep -c "手改" /etc/nginx/conf.d/site.conf | LC_ALL=C sed 's/^/        破坏后标记行数: /'
    ansible-playbook playbook.yml >/dev/null
    local marks
    marks=$(docker exec lab-nginx grep -c "手改" /etc/nginx/conf.d/site.conf || true)
    [ "$marks" = "0" ] && note "[ok] 配置已被 role 修复（漂移检出与回正一体）" || { note "[x] 未自愈" >&2; exit 1; }
}

do_vault() {
    step "vault" "Vault 取证：密文入库、渲染注入、轮换"
    note "git 视角的 vault.yml（密文）："
    head -2 group_vars/all/vault.yml | LC_ALL=C sed 's/^/        /'
    # 当前生效 token 一律以容器里渲染出来的为准（不硬编码，脚本可重复运行）
    local cur newtok
    cur=$(docker exec lab-nginx grep -oE 'X-Deploy-Token [a-z0-9-]+' /etc/nginx/conf.d/site.conf | awk '{print $2}')
    # 坑：$cur 后紧跟全角括号时，bash 会把多字节字符吃进变量名（报 cur\ufffd: unbound variable）
    # ——变量后接非 ASCII 字符必须用 ${cur} 花括号隔离，且冒号后留空格
    [ -n "${cur}" ] && note "[ok] 容器当前 token ${cur} - vault 变量已参与渲染" || { note "[x] 未渲染" >&2; exit 1; }

    note "密文文件里 grep 明文 token（应无结果）"
    if LC_ALL=C grep -q "${cur}" group_vars/all/vault.yml; then
        note "[x] 明文泄漏！" >&2; exit 1
    else
        note "[ok] 密文中无明文 token"
    fi

    note "轮换演示：解密 → 改值 → 重新加密 → 重跑 → 容器 token 更新"
    newtok="tok-$(date +%Y%m%d%H%M%S)-rotated"
    ansible-vault decrypt group_vars/all/vault.yml >/dev/null
    # 不用 sed 改这行：macOS BSD sed 对文件里的中文注释可能抛 illegal byte sequence
    { grep -v '^vault_deploy_token:' group_vars/all/vault.yml; echo "vault_deploy_token: $newtok"; } \
        > tmp/vault.yml.new && mv tmp/vault.yml.new group_vars/all/vault.yml
    ansible-vault encrypt group_vars/all/vault.yml >/dev/null
    ansible-playbook playbook.yml >/dev/null
    docker exec lab-nginx grep -q "${newtok}" /etc/nginx/conf.d/site.conf \
        && note "[ok] token 已轮换为 ${newtok} - 模板 changed 触发 handler reload" \
        || { note "[x] 轮换失败" >&2; exit 1; }
}

do_clean() {
    step "clean" "还原实验痕迹（容器回到镜像默认配置）"
    docker exec lab-nginx sh -c "rm -f /etc/nginx/conf.d/site.conf && nginx -s reload" 2>/dev/null || true
    rm -rf tmp
    note "[ok] 靶场 nginx 配置已还原（靶场本体属实验 05 管理，不在本实验销毁范围）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)      ensure_prereq; do_apply ;;
        idempotent) do_idempotent ;;
        drift)      do_drift ;;
        vault)      do_vault ;;
        clean)      do_clean ;;
        all)        ensure_prereq; do_apply; do_idempotent; do_drift; do_vault; do_clean ;;
        *) echo "可用: apply | idempotent | drift | vault | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
