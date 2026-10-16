#!/usr/bin/env bash
# =============================================================================
# 11 · 多 Provider 混合编排（一次跨三栈）— 主演示脚本
#
# 完整生命周期：apply → graph → clean
# 用法：
#   ./multi_provider.sh apply    # 一次 up 跨三 provider 建成，断言顺序与三视角
#   ./multi_provider.sh graph    # 从账本导出跨 provider 依赖边与同栈资源清点
#   ./multi_provider.sh clean    # destroy 后三世界零残留（底座 kind/LocalStack 保留）
#   ./multi_provider.sh          # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1

# aws 交叉验证：endpoint 指向 LocalStack + 假凭证
AWSLS=(aws --endpoint-url http://localhost:4566)
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true

PU="pulumi -C program"
LOGS=".logs"
CLUSTER="pulumi-lab"
NODE_IMAGE="kindest/node:v1.36.1"
NS="pulumi11-lab"
CTX="kind-$CLUSTER"
PORT=28701
BUCKET="pulumi11-payload"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

run() {
    local name="$1"; shift
    mkdir -p "$LOGS"
    $PU "$@" 2>&1 | tee "$LOGS/$name.log"
}

kc() { kubectl --context "$CTX" "$@"; }

ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    if [ ! -d program/node_modules ]; then
        note "首次运行：安装 TS 依赖（npm install，约 1 分钟）"
        (cd program && npm install --loglevel=error)
    fi
    if ! pulumi plugin ls 2>/dev/null | grep -q "aws.*resource.*7.50.0"; then
        note "预装 aws provider 插件 7.50.0（包大，首装约 2-3 分钟）"
        pulumi plugin install resource aws 7.50.0 2>&1 | tail -1 | sed 's/^/        /'
    fi
    mkdir -p .pulumi-state
}

# 两个底座：kind 集群与 LocalStack（复用 09/10 号实验的环境，不重复建设）
ensure_bases() {
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
        note "[ok] kind 集群 $CLUSTER 复用（09 号实验所建）"
    else
        note "创建专用 kind 集群 $CLUSTER"
        kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" 2>&1 | tail -1 | sed 's/^/        /'
    fi
    for img in nginx:1.27-alpine; do
        if ! docker exec "$CLUSTER-control-plane" crictl img 2>/dev/null \
            | grep "docker.io/library/nginx" | grep -q "${img##*:}"; then
            docker save "$img" \
                | docker exec -i "$CLUSTER-control-plane" ctr --namespace=k8s.io images import - \
                >/dev/null 2>&1
        fi
    done
    if curl -fsS http://localhost:4566/_localstack/health >/dev/null 2>&1; then
        note "[ok] LocalStack 复用（10 号实验所启）"
    else
        note "拉起 LocalStack"
        docker rm -f localstack-main >/dev/null 2>&1 || true
        localstack start -d 2>&1 | tail -1 | sed 's/^/        /'
        local i=0
        until curl -fsS http://localhost:4566/_localstack/health >/dev/null 2>&1; do
            i=$((i+1)); [ "$i" -gt 30 ] && { echo "    [!] LocalStack 60s 未就绪" >&2; exit 1; }
            sleep 2
        done
    fi
}

ensure_stack() {
    if ! $PU stack select dev >/dev/null 2>&1; then
        $PU stack init dev >/dev/null
        note "已创建栈 dev"
    fi
    $PU config set port "$PORT" --stack dev >/dev/null
}

do_apply() {
    step "apply" "一次 up 跨三 provider 建成（顺序由依赖图决定）"
    ensure_ready
    ensure_bases
    ensure_stack
    run up up --stack dev --yes
    if grep -q "created" "$LOGS/up.log"; then
        note "[ok] 创建完成"
    elif grep -q "unchanged" "$LOGS/up.log"; then
        note "[ok] 已在期望态（零变更，重跑幂等）"
    else
        echo "    [!] up 结果异常，看 ${LOGS}/up.log" >&2; exit 1
    fi
    note "顺序断言：aws(BucketObject) 创建行在 k8s(ConfigMap) 之前"
    local ao ko
    ao=$(grep -nE "aws:s3:BucketObject config-message created" "$LOGS/up.log" | head -1 | cut -d: -f1 || true)
    ko=$(grep -nE "kubernetes:core/v1:ConfigMap app-config created" "$LOGS/up.log" | head -1 | cut -d: -f1 || true)
    if [ -n "$ao" ] && [ -n "$ko" ]; then
        [ "$ao" -lt "$ko" ] || { echo "    [!] ConfigMap 竟排在 S3 对象之前" >&2; exit 1; }
        note "[ok] 行 $ao aws 创建 → 行 $ko k8s 创建：跨 provider 的 Output 流动兑现"
    else
        note "[ok] 重跑幂等（创建顺序留档见首跑）"
    fi
    note "三个世界各视角："
    "${AWSLS[@]}" s3 ls | grep "$BUCKET" | sed 's/^/        [aws] /'
    kc get deploy,cm -n "$NS" --no-headers | sed 's/^/        [k8s] /'
    docker ps --filter "name=pulumi11" --format "{{.Names}}  {{.Ports}}" | sed 's/^/        [docker] /'
    local body
    body=$(kc get configmap app-config -n "$NS" -o jsonpath='{.data.message}')
    [ "$body" = "greetings from LocalStack S3" ] \
        || { echo "    [!] ConfigMap 里不是 S3 的消息：$body" >&2; exit 1; }
    local env
    env=$(kc exec -n "$NS" deploy/app -- printenv MESSAGE 2>/dev/null || true)
    [ "$env" = "greetings from LocalStack S3" ] \
        || { echo "    [!] Pod 未拿到消息：$env" >&2; exit 1; }
    note "[ok] S3 的消息已流进 ConfigMap 并注入 Pod 环境（MESSAGE）"
    curl -fsS "http://localhost:$PORT/" >/dev/null || { echo "    [!] edge 容器无响应" >&2; exit 1; }
    note "[ok] edge 容器在 http://localhost:$PORT/（dependsOn 垫底）"
}

do_graph() {
    step "graph" "账本视角：同栈三类资源 + 跨 provider 依赖边"
    $PU stack export --stack dev 2>/dev/null > "$LOGS/state-export.json"
    python3 - "$LOGS/state-export.json" <<'PY'
import json, sys

d = json.load(open(sys.argv[1]))
res = d["deployment"]["resources"]
by_urn = {r["urn"]: r for r in res}

def short(urn):
    parts = urn.split("::")
    return f"{parts[-2]}::{parts[-1]}"

worlds = {}
print("        同栈资源清点（三世界记同一本账）：")
for r in res:
    if r["type"].startswith("pulumi:"):
        continue
    world = r["type"].split(":")[0]
    worlds.setdefault(world, []).append(short(r["urn"]))
for w in sorted(worlds):
    print(f"        [{w}] {len(worlds[w])} 条: " + ", ".join(sorted(worlds[w])))
assert set(worlds) == {"aws", "kubernetes", "docker"}, f"三世界不全：{set(worlds)}"

print("        跨 provider 依赖边：")
cross = []
for r in res:
    me, my_world = short(r["urn"]), r["type"].split(":")[0]
    for dep in r.get("dependencies", []):
        dep_world = by_urn[dep]["type"].split(":")[0]
        if dep_world != my_world:
            cross.append(f"        [{dep_world}] {short(dep)} --dependsOn--> [{my_world}] {me}")
    for prop, deps in (r.get("propertyDependencies") or {}).items():
        for dep in deps:
            dep_world = by_urn[dep]["type"].split(":")[0]
            if dep_world != my_world:
                cross.append(f"        [{dep_world}] {short(dep)} --{prop}--> [{my_world}] {me}")
for e in sorted(set(cross)):
    print(e)
assert any("--data-->" in e for e in cross), "缺 S3→ConfigMap 的属性依赖边"
assert any("app" in e and "edge" in e for e in cross), "缺 k8s→docker 的 dependsOn 边"
print("        [ok] 跨 provider 依赖边都在账本里——三个世界一张图")
PY
}

do_clean() {
    step "clean" "destroy 后三世界零残留"
    if $PU stack select dev >/dev/null 2>&1; then
        run destroy destroy --stack dev --yes
    fi
    if "${AWSLS[@]}" s3 ls 2>/dev/null | grep -q "$BUCKET"; then
        echo "    [!] aws 世界残留：桶 $BUCKET 仍在" >&2; exit 1
    fi
    if kc get namespace "$NS" >/dev/null 2>&1; then
        echo "    [!] k8s 世界残留：ns $NS 仍在" >&2; exit 1
    fi
    if docker ps -a --format '{{.Names}}' | grep -q '^pulumi11'; then
        echo "    [!] docker 世界残留：edge 容器仍在" >&2; exit 1
    fi
    note "[ok] aws / kubernetes / docker 三世界零残留；底座（kind 集群与 LocalStack）保留"
    rm -rf "$LOGS"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)  do_apply ;;
        graph)  do_graph ;;
        clean)  do_clean ;;
        all)    do_apply; do_graph; do_clean ;;
        *) echo "可用: apply | graph | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
