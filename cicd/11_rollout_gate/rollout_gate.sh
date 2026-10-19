#!/usr/bin/env bash
# =============================================================================
# 11 · 滚动更新与健康门禁（kind）— 主演示脚本
#
# 完整生命周期：up → good → bad → undo → clean
# 用法：
#   ./rollout_gate.sh up      # 起 kind 集群 + 三版本镜像 + v1 三副本
#   ./rollout_gate.sh good    # 好版本滚动更新：压测中滚动，断言 0 失败
#   ./rollout_gate.sh bad     # 坏版本：readiness 拦截——rollout 卡住、坏副本不接流量
#   ./rollout_gate.sh undo    # rollout undo 恢复全绿
#   ./rollout_gate.sh clean   # 删集群，恢复原 kubectl context
#   ./rollout_gate.sh         # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=cicd11-rollout
NODE="${CLUSTER}-control-plane"
CTX="kind-${CLUSTER}"
HOST_PORT=29090
LOGS=.logs

KC=(kubectl --context "${CTX}")

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# 打 $1 个请求到 Service 的 /version，输出 "v1 v2 bad empty" 计数
fire() {
    local n="$1" out v1 v2 bad
    out="$(seq 1 "${n}" | xargs -P 8 -I{} curl -s --max-time 2 \
        "http://127.0.0.1:${HOST_PORT}/version" 2>/dev/null | sort | uniq -c || true)"
    v1="$(awk '$2=="v1"{print $1}' <<< "${out}")"; v1="${v1:-0}"
    v2="$(awk '$2=="v2"{print $1}' <<< "${out}")"; v2="${v2:-0}"
    bad="$(awk '$2=="bad"{print $1}' <<< "${out}")"; bad="${bad:-0}"
    echo "${v1} ${v2} ${bad} $((n - v1 - v2 - bad))"
}

ready_count() {
    "${KC[@]}" get pods -l app=roll-demo --no-headers 2>/dev/null \
        | awk '{print $2}' | sort | uniq -c | tr '\n' ' ' || true
}

endpoint_ips() {
    "${KC[@]}" get endpoints roll-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true
}

wait_rollout_ok() {
    "${KC[@]}" rollout status deployment/roll-demo --timeout=60s
}

build_images() {
    local v tag dir
    for v in v1 v2 bad; do
        tag="roll:${v}"
        dir="docker/${v}"
        if ! docker image inspect "${tag}" >/dev/null 2>&1; then
            docker build -q -t "${tag}" "${dir}" >/dev/null
            note "镜像 ${tag} 已构建"
        fi
        # kind 节点不共享宿主机镜像——docker save | ctr import 离线注入
        docker save "${tag}" | docker exec -i "${NODE}" \
            ctr --namespace=k8s.io images import - >/dev/null 2>&1
    done
}

do_up() {
    step "up" "起 kind 集群 + 三版本镜像 + v1 三副本"
    mkdir -p "${LOGS}"
    kubectl config current-context > .ctx.orig   # 保护用户当前 context，clean 时恢复
    if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
        kind create cluster --name "${CLUSTER}" --config k8s/cluster.yaml --wait 90s
    else
        note "集群 ${CLUSTER} 已存在，复用"
    fi
    build_images
    "${KC[@]}" apply -f k8s/app.yaml >/dev/null
    wait_rollout_ok
    note "[ok] v1 三副本 rollout 完成（$(ready_count)）"
    fire 50 > /dev/null   # 预热：apply 后首个突发可能撞上端口映射/conntrack 冷启动
    sleep 1
    local read v1 v2 bad empty
    read -r v1 v2 bad empty <<< "$(fire 100)"
    [ "${v1}" = "100" ] \
        || { echo "        [!] 基线应为 100% v1，实测 v1×${v1} v2×${v2} bad×${bad} 空×${empty}" >&2; exit 1; }
    note "[ok] 基线 100 请求全量 v1"
}

do_good() {
    step "good" "好版本滚动更新：压测中滚动 v1→v2，断言 0 失败"
    : > "${LOGS}/good_samples.log"
    ab -q -t 18 -n 200000 -c 5 "http://127.0.0.1:${HOST_PORT}/version" \
        > "${LOGS}/good_ab.log" 2>&1 &
    local ab_pid=$!
    ( while :; do
        printf '%s\n' "$(curl -s --max-time 2 "http://127.0.0.1:${HOST_PORT}/version" | tr -d '\n')" \
            >> "${LOGS}/good_samples.log"
        sleep 0.15
      done ) &
    local sampler_pid=$!
    sleep 3
    "${KC[@]}" set image deployment/roll-demo web=roll:v2 >/dev/null
    wait_rollout_ok
    note "[ok] v2 滚动完成（$(ready_count)）"
    wait "${ab_pid}" || true
    kill "${sampler_pid}" 2>/dev/null || true
    wait "${sampler_pid}" 2>/dev/null || true
    # ab 遇连接重置会整场中止、不输出统计表——先验完整性再解析
    if ! grep -q '^Complete requests:' "${LOGS}/good_ab.log"; then
        echo "        [!] ab 异常中止：$(tail -1 "${LOGS}/good_ab.log")" >&2
        exit 1
    fi
    local failed complete
    failed="$(grep -E '^Failed requests:' "${LOGS}/good_ab.log" | awk '{print $3}')"
    complete="$(grep -E '^Complete requests:' "${LOGS}/good_ab.log" | awk '{print $3}')"
    [ "${failed}" = "0" ] || { echo "        [!] 滚动期间压测失败请求 ${failed}" >&2; exit 1; }
    note "[ok] 滚动全程压测 ${complete} 请求，Failed requests: 0（maxUnavailable 0：容量永不下降）"
    local s_v1 s_v2 s_other
    s_v1="$(grep -c '^v1$' "${LOGS}/good_samples.log" || true)"
    s_v2="$(grep -c '^v2$' "${LOGS}/good_samples.log" || true)"
    s_other="$(grep -cvE '^(v1|v2)$' "${LOGS}/good_samples.log" || true)"
    [ "${s_v1}" -gt 0 ] && [ "${s_v2}" -gt 0 ] && [ "${s_other}" = "0" ] \
        || { echo "        [!] 采样异常：v1×${s_v1} v2×${s_v2} 其他×${s_other}" \
                "$(grep -vE '^(v1|v2)$' "${LOGS}/good_samples.log" | sort | uniq -c | head -3)" >&2; exit 1; }
    note "[ok] 采样时间线：v1 × ${s_v1} → v2 × ${s_v2}，无空窗无 5xx（${s_other} 个异常）"
    local read v1 v2 bad empty
    read -r v1 v2 bad empty <<< "$(fire 200)"
    [ "${v2}" = "200" ] \
        || { echo "        [!] 更新后应 100% v2，实测 v1×${v1} v2×${v2}" >&2; exit 1; }
    note "[ok] 更新后 200 请求全量 v2"
}

do_bad() {
    step "bad" "坏版本：readiness 拦截——rollout 卡住、坏副本不接流量"
    # 注入前先记录当前在服版本：紧跟 good 跑时是 v2，单独跑（紧随 up）是 v1
    local prev
    prev="$(curl -s --max-time 2 "http://127.0.0.1:${HOST_PORT}/version" | tr -d '\n')"
    "${KC[@]}" set image deployment/roll-demo web=roll:bad >/dev/null
    if wait_rollout_ok; then
        echo "        [!] 坏版本 rollout 竟然完成——readiness 未拦截" >&2
        exit 1
    fi
    note "[ok] rollout status 非零退出：progressDeadlineSeconds 30s 判定进展停滞"
    local reason
    reason="$("${KC[@]}" get deployment roll-demo \
        -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}')"
    [ "${reason}" = "ProgressDeadlineExceeded" ] \
        || { echo "        [!] Deployment 原因异常：${reason}" >&2; exit 1; }
    note "[ok] Deployment condition: Progressing reason=${reason}"
    sleep 2
    local ones zeros
    ones="$("${KC[@]}" get pods -l app=roll-demo --no-headers 2>/dev/null | grep -c ' 1/1 ' || true)"
    zeros="$("${KC[@]}" get pods -l app=roll-demo --no-headers 2>/dev/null | grep -c ' 0/1 ' || true)"
    [ "${ones}" = "3" ] && [ "${zeros}" = "1" ] \
        || { echo "        [!] 副本状态异常：1/1 × ${ones}，0/1 × ${zeros}" >&2; exit 1; }
    note "[ok] 副本状态：1/1 × ${ones}、0/1 × ${zeros}——旧副本 3 个继续服务，坏副本卡在 Ready 门外"
    local n_ep
    n_ep="$(endpoint_ips | wc -w | tr -d ' ')"
    [ "${n_ep}" = "3" ] \
        || { echo "        [!] endpoints 应只有 3 个 IP（坏副本不进），实际 ${n_ep}" >&2; exit 1; }
    note "[ok] Service endpoints 仅 3 个 IP——readiness 不过 = 不进 endpoints = 不接流量"
    local read v1 v2 bad empty
    read -r v1 v2 bad empty <<< "$(fire 100)"
    [ "${bad}" = "0" ] && [ "${empty}" = "0" ] \
        && { [ "${v1}" = "100" ] || [ "${v2}" = "100" ]; } \
        || { echo "        [!] 卡住期间应 100% 旧版本，实测 v1×${v1} v2×${v2} bad×${bad} 空×${empty}" >&2; exit 1; }
    note "[ok] 卡住期间 100 请求全量 $([ "${v1}" = "100" ] && echo v1 || echo v2)、零 500——用户完全无感"
}

do_undo() {
    step "undo" "rollout undo 回到上一个好版本（不是回到 v1——回滚只退一步）"
    "${KC[@]}" rollout undo deployment/roll-demo >/dev/null
    wait_rollout_ok
    note "[ok] 回滚完成（$(ready_count)；0/1 为被替换副本收尾中）"
    local img want
    img="$("${KC[@]}" get deployment roll-demo \
        -o jsonpath='{.spec.template.spec.containers[0].image}')"
    want="${img##roll:}"
    local read v1 v2 bad empty
    read -r v1 v2 bad empty <<< "$(fire 200)"
    local served=0
    [ "${want}" = "v1" ] && served="${v1}" || served="${v2}"
    [ "${bad}" = "0" ] && [ "${empty}" = "0" ] && [ "${served}" = "200" ] \
        || { echo "        [!] 恢复后应 100% ${want}，实测 v1×${v1} v2×${v2} bad×${bad} 空×${empty}" >&2; exit 1; }
    note "[ok] 恢复后 200 请求全量 ${want}（镜像 ${img}）——一条 undo 回到上一个好版本"
}

do_clean() {
    step "clean" "删集群，恢复原 kubectl context"
    kind delete cluster --name "${CLUSTER}" 2>/dev/null || true
    if [ -f .ctx.orig ]; then
        kubectl config use-context "$(cat .ctx.orig)" >/dev/null 2>&1 || true
        rm -f .ctx.orig
    fi
    rm -rf "${LOGS}"
    note "[ok] 集群已删；context 已恢复；日志已清"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)    do_up ;;
        good)  do_good ;;
        bad)   do_bad ;;
        undo)  do_undo ;;
        clean) do_clean ;;
        all)   do_up; do_good; do_bad; do_undo; do_clean ;;
        *) echo "可用: up | good | bad | undo | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
