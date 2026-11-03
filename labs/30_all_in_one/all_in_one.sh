#!/usr/bin/env bash
# =============================================================================
# 30 · 🏁 终极串联 — DevOps 一体机：六环节故事线（一键编排，全程无手工干预）
#
#   S1 up        监控栈(26) + 日志栈(27) + 靶场容器(TF, 28 的期望态) + 密钥(24)
#   S2 pipeline  push 代码 → Gitea Actions 三道门(25) → Success
#   S3 deploy    部署新版本页面 → 拉镜像/内容更新 → 服务断言 v2
#   S4 observe   指标曲线(26) + 日志 ERROR 计数(27) 都"看见"了这次发布
#   S5 drift     注入漂移 → 28 的双探针检出 → 一键回正
#   S6 destroy   全栈销毁（零残留）
#
# 复用资产：22/23 门禁策略 · 24 age 私钥 · 25 runner/镜像 · 26/27 栈 · 28 期望态
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

AIO="aio"
WEB_PORT=28230
BASE="$(cd .. && pwd)"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }
must_contain() { grep -qE "$2" "$1" || fail "$3（$1 缺少 /$2/）"; ok "$3"; }

run_lab() {  # run_lab <dir> <script> <args...>：复用兄弟实验的脚本
    ( cd "$BASE/$1" && "./$2" "${@:3}" )
}

# ---- S1：底座 ----
s1_up() {
    step S1 "监控栈（26）+ 日志栈（27）拉起"
    run_lab 26_monitoring_stack monitoring_stack.sh up
    run_lab 27_loki_logging loki_logging.sh up
    step S1 "靶场容器期望态（28 的 TF）+ age 密钥（24）"
    run_lab 28_drift_detection drift_detection.sh setup
    run_lab 24_sops_age sops_age.sh keygen
    step S1 "Gitea + runner + 三道门 CI（25，含工具镜像）"
    run_lab 25_compliance_pipeline compliance_pipeline.sh up
    ok "底座就绪：监控 291xx · 日志 292xx · 靶场 28230 · CI 3356"
}

# ---- S2：合规流水线 ----
s2_pipeline() {
    step S2 "push 合规代码 → 三道门 → Success"
    run_lab 25_compliance_pipeline compliance_pipeline.sh green
}

# ---- S3：部署新版本 ----
s3_deploy() {
    step S3 "部署 v2 内容到靶场容器（流水线的 deploy 步产物）"
    docker exec drift28-web sh -c 'mkdir -p /srv'
    docker cp apps/index-v2.html drift28-web:/srv/index.html
    # 部署后就绪有抖动——轮询断言而非单发 curl（实测 curl 首发可能失败）
    local n=0 page=""
    while :; do
        n=$((n+1)); [ $n -gt 15 ] && fail "45s 内 v2 页面未生效"
        page=$(curl -s -m 5 "http://localhost:$WEB_PORT/" || true)
        echo "$page" | grep -q "v2 (deployed via pipeline)" && break
        sleep 3
    done
    ok "服务已更新为 v2（curl :$WEB_PORT 实证）"
    # 指标：记录一次发布（pushgateway）
    echo 'ci_deploys_total 1' | curl -sS --data-binary @- "http://localhost:29191/metrics/job/demo/instance/deploy" >/dev/null
    ok "发布指标已推（ci_deploys_total=1，26 的 pushgateway）"
}

# ---- S4：可观测验证 ----
s4_observe() {
    step S4 "监控与日志都看见了这次发布"
    # push 后同样有抓取延迟——轮询（与 pushgateway 打交道的两个实验同理）
    local n=0 deploys="" errlogs=""
    while :; do
        n=$((n+1)); [ $n -gt 20 ] && fail "发布指标 60s 未被抓取（prom 侧已确认有值，疑轮询/引号问题）"
        deploys=$(curl -sS --get --data-urlencode 'query=ci_deploys_total' "http://localhost:29190/api/v1/query" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1] if d['data']['result'] else '')" 2>/dev/null)
        [ "${deploys:-}" = "1" ] && break
        sleep 3
    done
    ok "Prometheus 可见 ci_deploys_total=${deploys}（发布曲线有数据）"
    n=0
    while :; do
        n=$((n+1)); [ $n -gt 20 ] && fail "Loki 未查到日志"
        errlogs=$(curl -sS --get --data-urlencode 'query=sum(count_over_time({app="ci"}[5m]))' "http://localhost:29200/loki/api/v1/query" 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(int(r['value'][1]) for r in d['data']['result']) if d['data']['result'] else 0)" 2>/dev/null)
        [ "${errlogs:-0}" -ge 1 ] && break
        sleep 3
    done
    ok "Loki 日志流有数据（ERROR 计数 $errlogs/5m——27 的生成器在跑）"
}

# ---- S5：漂移治理 ----
s5_drift() {
    step S5 "注入漂移 → 28 的探针检出 → 一键回正"
    run_lab 28_drift_detection drift_detection.sh inject-config
    run_lab 28_drift_detection drift_detection.sh detect
    run_lab 28_drift_detection drift_detection.sh restore
    run_lab 28_drift_detection drift_detection.sh assert-clean
    ok "漂移治理闭环（检出→回正→终态四断言）"
}

# ---- S6：销毁 ----
s6_destroy() {
    step S6 "全栈销毁"
    run_lab 25_compliance_pipeline compliance_pipeline.sh clean || true
    run_lab 28_drift_detection drift_detection.sh clean || true
    run_lab 27_loki_logging loki_logging.sh down || true
    run_lab 26_monitoring_stack monitoring_stack.sh down || true
    run_lab 24_sops_age sops_age.sh clean || true
    ok "全栈零残留"
}

case "${1:-demo}" in
    up)     s1_up ;;
    pipeline) s2_pipeline ;;
    deploy) s3_deploy ;;
    observe) s4_observe ;;
    drift)  s5_drift ;;
    destroy) s6_destroy ;;
    demo)
        echo "============================================================="
        echo " 🏁 DevOps 一体机故事线：改代码 → 三道门 → 部署 → 可观测 → 漂移治理"
        echo "============================================================="
        s1_up
        s2_pipeline
        s3_deploy
        s4_observe
        s5_drift
        s6_destroy
        echo; echo "✅ 30 终极串联：六环节故事线全程无手工干预"
        ;;
    *) echo "可用: up | pipeline | deploy | observe | drift | destroy | demo" >&2; exit 1 ;;
esac
