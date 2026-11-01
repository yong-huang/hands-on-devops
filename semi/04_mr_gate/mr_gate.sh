#!/usr/bin/env bash
# semi/04_mr_gate · 集成点①：平台验收 + 第一个 MR 评审流
# 用法：./mr_gate.sh up | verify | status | clean
#   up     webhook 监听容器上线 + 事件钩子注册 + MR 评审流（dev1 推分支→开 MR→root 审批→合并）
#   verify acceptance.py 九条断言（组树/成员/双项目/保护分支/hook/LFS/webhook 注册/事件/MR 证据）
#   status 监听器事件流 + rtl-gcd hook 列表
#   clean  摘除 webhook + 删监听容器（组树/项目/MR 历史保留——它们是真实平台资产）
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE=".root-token"
TOKEN_FALLBACK="../02_org_guard/.root-token"
DEV1_TOKEN_FILE=".dev1-token"
LISTEN_NET="semi-gitlab_default"          # 01 compose 项目的默认网络
HOOK_URL="http://webhook-listener:9000/hook"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }

ensure_root_token() {
    for cand in "$TOKEN_FILE" "$TOKEN_FALLBACK"; do
        if [ -s "$cand" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                -H "PRIVATE-TOKEN: $(cat "$cand")" "$URL/api/v4/user")" = "200" ]; then
            [ "$cand" != "$TOKEN_FILE" ] && { cp "$cand" "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; }
            echo "[  =] root token: $cand"
            return 0
        fi
    done
    echo "[fail] 无有效 root token（跑一次 02 的 ./org_guard.sh up 可重签）"; exit 1
}

ensure_dev1_token() {
    if [ -s "$DEV1_TOKEN_FILE" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -H "PRIVATE-TOKEN: $(cat "$DEV1_TOKEN_FILE")" "$URL/api/v4/user")" = "200" ]; then
        echo "[  =] dev1 token 有效，复用"
        return 0
    fi
    docker exec gitlab rm -f /tmp/dev1_token.rb
    docker cp scripts/dev1_token.rb gitlab:/tmp/dev1_token.rb
    local tok
    tok=$(docker exec gitlab gitlab-rails runner /tmp/dev1_token.rb 2>/dev/null | tail -1)
    [ -n "$tok" ] || { echo "[fail] dev1 token 签发失败（02 的 dev1 用户在位吗？）"; exit 1; }
    printf '%s' "$tok" > "$DEV1_TOKEN_FILE"; chmod 600 "$DEV1_TOKEN_FILE"
    docker exec gitlab rm -f /tmp/dev1_token.rb
    echo "[ok] dev1 PAT 已签发（semi-dev1）"
}

start_listener() {
    step listener "webhook 监听容器（stdlib HTTP 记录器，零依赖）"
    docker rm -f webhook-listener >/dev/null 2>&1 || true
    docker pull -q docker.1ms.run/library/python:3.12-slim >/dev/null 2>&1 || \
        docker pull -q docker.m.daocloud.io/library/python:3.12-slim >/dev/null
    docker run -d --name webhook-listener --network "$LISTEN_NET" --label dev.orbstack.group=semi-cicd \
        -v "$PWD/data:/data" -v "$PWD/scripts/server.py:/app/server.py:ro" \
        -p 127.0.0.1:28270:9000 \
        docker.1ms.run/library/python:3.12-slim python /app/server.py >/dev/null
    sleep 2
    curl -sf http://localhost:28270/health >/dev/null &&
        pass "监听器健康（宿主探针 :28270，容器内名 webhook-listener）" ||
        { fail "监听器未就绪"; docker logs webhook-listener | tail -3; exit 1; }
}

register_webhook() {
    step webhook "在 rtl-gcd 注册事件钩子（push + merge_request，幂等）"
    # GitLab 默认禁止 webhook 打内网地址（422）：管理员设置放行 local network（幂等）
    curl -s -X PUT -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/application/settings?allow_local_requests_from_web_hooks_and_services=true" \
        | python3 -c "import sys,json;d=json.load(sys.stdin);print('[  =] 本地网络 webhook 放行:', d.get('allow_local_requests_from_web_hooks_and_services'))" || true
    local pid
    pid=$(curl -s --max-time 10 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    local have
    have=$(curl -s -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/projects/$pid/hooks" |
        python3 -c "import sys,json;print(sum('webhook-listener:9000' in h['url'] for h in json.load(sys.stdin)))")
    if [ "$have" -ge 1 ]; then
        echo "[  =] webhook 已注册，跳过"
    else
        curl -s -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" -X POST "$URL/api/v4/projects/$pid/hooks" \
            -d "url=$HOOK_URL" -d "push_events=true" -d "merge_requests_events=true" \
            -d "enable_ssl_verification=false" | python3 -c "import sys,json;h=json.load(sys.stdin);print('[ok] webhook id=%s -> %s' % (h.get('id'), h.get('url')))"
    fi
    # 探活：从 gitlab 容器内 ping 监听器（同网络自带 DNS）
    docker exec gitlab curl -sf --max-time 8 http://webhook-listener:9000/health >/dev/null &&
        pass "gitlab -> webhook-listener 网络互通" ||
        { fail "gitlab 容器解析不到 webhook-listener（网络 $LISTEN_NET 对吗？）"; exit 1; }
}

run_mr_flow() {
    step flow "第一个 MR 评审流（dev1 推分支 -> 开 MR -> root 审批 -> 合并）"
    DEV1_PWD=$(python3 -c "import yaml;print(yaml.safe_load(open('../02_org_guard/configs/org.yaml'))['users'][0]['password'])")
    python3 scripts/mr_flow.py "$(cat "$TOKEN_FILE")" "$(cat "$DEV1_TOKEN_FILE")" "$DEV1_PWD"
}

do_up() {
    ensure_root_token
    start_listener
    register_webhook
    ensure_dev1_token
    run_mr_flow
    ./mr_gate.sh verify
}

do_verify() {
    step verify "平台一键自检（acceptance.py 九条断言）"
    python3 scripts/acceptance.py "$(cat "$TOKEN_FILE")" data/events.json
}

do_status() {
    step status "监听器事件流（最近 5 条）"
    python3 -c "
import json
ev = json.load(open('data/events.json'))
for e in ev[-5:]:
    print(f\"  {e['time']} {e['kind']:<14} {e['action']:<6} {e['user']:<8} {e['project']} {e['ref']}\")
print(f'  共 {len(ev)} 条')"
    step status "rtl-gcd webhooks"
    curl -s -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/semi%2Fip%2Fdesign%2Frtl-gcd/hooks" |
        python3 -c "import sys,json;[print(f\"  #{h['id']} {h['url']} push={h['push_events']} mr={h['merge_requests_events']}\") for h in json.load(sys.stdin)]"
}

do_clean() {
    step clean "摘 webhook + 删监听容器（平台资产保留）"
    local pid
    pid=$(curl -s -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])" 2>/dev/null || true)
    if [ -n "$pid" ]; then
        for hid in $(curl -s -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/projects/$pid/hooks" |
            python3 -c "import sys,json;[print(h['id']) for h in json.load(sys.stdin) if 'webhook-listener:9000' in h['url']]"); do
            curl -s -X DELETE -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/projects/$pid/hooks/$hid" >/dev/null
        done
        echo "[ok] webhook 已摘除"
    fi
    docker rm -f webhook-listener >/dev/null 2>&1 && echo "[ok] 监听容器已删"
}

main() {
    local target="${1:-up}"
    case "${target}" in
        up)     do_up ;;
        verify) do_verify ;;
        status) do_status ;;
        clean)  do_clean ;;
        *) echo "用法: $0 up | verify | status | clean" >&2; exit 1 ;;
    esac
}
main "$@"
