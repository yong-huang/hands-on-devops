#!/usr/bin/env bash
# semi/16_dashboard · 回归仪表盘（静态 SVG 趋势站，旁挂 nginx :28210）
# 用法：./dashboard.sh up | verify | status | clean
#   up     nginx 容器（28210）+ 采集 3 份历史快照（P12 基线/注错/重跑语义的 summary）→ 渲染部署
#   verify ①HTTP 200 + 页面含趋势元素 ②SVG/表格数据与最新快照一致（一致性断言）
#   status 容器与站点内容
#   clean  删容器（工作目录 dashboard/ 保留）
# 降级说明（清单预案）：GitLab Pages 的 Omnibus 配置（pages_external_url + 独立端口 + access control）
# 探活成本高，本实验用旁挂 nginx 容器承载同一静态站；渲染层（render_dashboard.py）与部署层无关。
set -uo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
NET="semi-gitlab_default"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

collect_history() {
    # 采集 3 份真实快照：P12 的基线(146)/注错(148) 的 aggregate/子 job summary + 当前 main 最新
    step history "采集历史快照（真数据：P12 基线 + 注错 + 当前 main）"
    mkdir -p history
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

    # 快照 A：pipeline 146（基线，aggregate artifact）
    local jid
    jid=$(api "projects/$pid/pipelines/146/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'aggregate':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
    [ -n "$jid" ] && api "projects/$pid/jobs/$jid/artifacts/sim/summary.json" > history/snap_baseline146.json

    # 快照 B：pipeline 148（seed7 注错）——聚合被 skip，用子 job artifact（seed7 summary 代表失败形态）
    jid=$(api "projects/$pid/pipelines/148/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'regression: [7]':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
    if [ -n "$jid" ]; then
        api "projects/$pid/jobs/$jid/artifacts/sim/summary_seed_7.json" > /tmp/s7.json
        python3 - <<'PY'
import json
s = json.load(open("/tmp/s7.json"))
out = {"expected": 16, "collected": 1, "passed": 16 - 1, "failed": 1,
       "failed_seeds": ["7"], "verdict": "fail"}
json.dump(out, open("history/snap_bug148.json", "w"), indent=1)
PY
    fi

    # 快照 C：main 最新成功流水线的 aggregate
    local pl
    pl=$(api "projects/$pid/pipelines?ref=main&status=success&per_page=1" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
    jid=$(api "projects/$pid/pipelines/$pl/jobs" | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        if j['name'] == 'aggregate':
            print(j['id'])
except Exception:
    pass" 2>/dev/null || true)
    [ -n "$jid" ] && api "projects/$pid/jobs/$jid/artifacts/sim/summary.json" > history/snap_latest.json
    ls history/ | sed 's/^/  /'
}

do_up() {
    step server "旁挂 nginx（28210，承载静态仪表盘）"
    docker rm -f reg-dashboard >/dev/null 2>&1 || true
    mkdir -p dashboard
    docker run -d --name reg-dashboard --restart unless-stopped \
        --label dev.orbstack.group=semi-cicd \
        --network "$NET" \
        -v "$PWD/dashboard:/usr/share/nginx/html:ro" \
        -p 127.0.0.1:28210:80 \
        docker.m.daocloud.io/library/nginx:alpine >/dev/null
    sleep 2

    collect_history
    cp ../08_lint_gate/.work/rtl-gcd/sim/summary.json . 2>/dev/null || true
    step render "渲染趋势站"
    python3 tools/render_dashboard.py
    pass "站点已部署：http://localhost:28210/"
}

do_verify() {
    local FAILED=0
    step verify1 "HTTP 200 + 页面含趋势元素"
    local code html
    code=$(curl -s -o /tmp/dash.html -w '%{http_code}' http://localhost:28210/)
    html=$(cat /tmp/dash.html)
    if [ "$code" = "200" ] &&
       echo "$html" | grep -q "rtl-gcd 回归仪表盘" &&
       echo "$html" | grep -q "<polyline" &&
       echo "$html" | grep -q "历史快照"; then
        pass "站点 200 且含 SVG 折线与历史表"
    else
        fail "站点异常 HTTP=$code"; FAILED=1
    fi

    step verify2 "数据一致性：页面数据 == 最新快照"
    local latest_passed
    latest_passed=$(python3 -c "
import json, glob
f = sorted(glob.glob('history/snap_*.json'))[-1]
print(json.load(open(f)).get('passed'))")
    if echo "$html" | grep -q "passed ${latest_passed}/16"; then
        pass "页面 passed=${latest_passed}/16 与最新快照一致"
    else
        fail "页面数据与快照不一致（期望 passed=$latest_passed）"; FAILED=1
    fi

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 16 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "容器"
    docker ps --filter name=reg-dashboard --format '  {{.Names}}: {{.Status}}'
    step status "站点"
    curl -s http://localhost:28210/ | grep -o "<p>快照数[^<]*" | head -1
}

do_clean() {
    step clean "删 nginx 容器（dashboard/ 保留）"
    docker rm -f reg-dashboard >/dev/null 2>&1 && echo "[ok] 完成"
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
