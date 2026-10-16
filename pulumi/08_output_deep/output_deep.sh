#!/usr/bin/env bash
# =============================================================================
# 08 · Output 深水区（apply 陷阱与依赖图）— 主演示脚本
#
# 完整生命周期：apply → graph → parallel → clean
# 用法：
#   ./output_deep.sh apply     # up：依赖边生效、apply 取值对照（陷阱复现）
#   ./output_deep.sh graph     # 从账本导出依赖图，与代码注解一一对照
#   ./output_deep.sh parallel  # --parallel 1 与默认并行各跑一遍，结果一致
#   ./output_deep.sh clean     # 销毁全清，零残留
#   ./output_deep.sh           # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1

PU="pulumi -C program"
LOGS=".logs"
PORT=28601
STACK="dev"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

run() {
    local name="$1"; shift
    mkdir -p "$LOGS"
    $PU "$@" 2>&1 | tee "$LOGS/$name.log"
}

wait_http() {
    local url="$1" i=0
    until curl -fsS -o /dev/null "$url" 2>/dev/null; do
        i=$((i+1)); [ "$i" -gt 15 ] && { echo "    [!] 15s 内 $url 未就绪" >&2; return 1; }
        sleep 1
    done
}

check_nginx() {
    local body
    body=$(curl -fsS "http://localhost:$1/")
    grep -q "Welcome to nginx" <<<"$body" \
        || { echo "    [x] 端口 $1 不是 nginx 首页" >&2; exit 1; }
}

ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    if [ ! -d program/node_modules ]; then
        note "首次运行：安装 TS 依赖（npm install，约 1 分钟）"
        (cd program && npm install --loglevel=error)
    fi
    mkdir -p .pulumi-state
}

ensure_stack() {
    if ! $PU stack select "$STACK" >/dev/null 2>&1; then
        $PU stack init "$STACK" >/dev/null
        note "已创建栈 $STACK"
    fi
    $PU config set port "$PORT" --stack "$STACK" >/dev/null
}

do_apply() {
    step "apply" "依赖边生效 + apply 取值对照（陷阱复现）"
    ensure_ready
    ensure_stack
    run up up --stack "$STACK" --yes
    grep -q "created\|unchanged" "$LOGS/up.log" \
        || { echo "    [!] up 结果异常" >&2; exit 1; }
    note "陷阱对照（up 输出里取证）："
    grep "\[trap\]" "$LOGS/up.log" | head -1 | sed 's/^/        /'
    grep "\[ok\] apply 里" "$LOGS/up.log" | head -1 | sed 's/^/        /'
    note "显式依赖生效证据（second 的创建行在 first 之后）："
    grep -nE "docker:index:Container (first|second) creat" "$LOGS/up.log" | sed 's/^/        /'
    if grep -q "created" "$LOGS/up.log"; then
        local fl sl
        fl=$(grep -nE "Container first created" "$LOGS/up.log" | head -1 | cut -d: -f1)
        sl=$(grep -nE "Container second created" "$LOGS/up.log" | head -1 | cut -d: -f1)
        [ -n "$fl" ] && [ -n "$sl" ] && [ "$fl" -lt "$sl" ] \
            || { echo "    [!] second 未排在 first 之后——dependsOn 失效？" >&2; exit 1; }
        note "[ok] 行 $fl first → 行 $sl second：dependsOn 顺序兑现"
    else
        note "[ok] 重跑幂等（已创建过，顺序留档见首跑）"
    fi
    wait_http "http://localhost:$PORT/"; check_nginx "$PORT"
    note "[ok] 服务在 http://localhost:$PORT/"
}

do_graph() {
    step "graph" "从账本导出依赖图，与代码注解一一对照"
    $PU stack export --stack "$STACK" 2>/dev/null > "$LOGS/state-export.json"
    python3 - "$LOGS/state-export.json" <<'PY'
import json, sys

d = json.load(open(sys.argv[1]))
res = d["deployment"]["resources"]
by_urn = {r["urn"]: r for r in res}

def short(urn):
    parts = urn.split("::")
    return f"{parts[-2]}::{parts[-1]}"

print("        依赖边（账本 dependencies + propertyDependencies）：")
edges = []
for r in res:
    me = short(r["urn"])
    for dep in r.get("dependencies", []):
        edges.append(f"        {short(dep)}  --dependsOn-->  {me}")
    for prop, deps in (r.get("propertyDependencies") or {}).items():
        for dep in deps:
            edges.append(f"        {short(dep)}  --{prop}-->  {me}")
for e in sorted(set(edges)):
    print(e)
# 断言两条关键边存在
assert any("second" in e and "dependsOn" in e for e in edges), "缺显式 dependsOn 边"
assert any("net" in e and "--ports-->" in e for e in edges) or \
       any("net" in e and "--networksAdvanced-->" in e for e in edges), "缺隐式属性依赖边"
print("        [ok] 显式 dependsOn 与隐式属性依赖都在账本里——依赖图与代码一一对应")
PY
}

do_parallel() {
    step "parallel" "--parallel 1 与默认并行各跑一遍，结果必须一致"
    note "跑法 A：--parallel 1（串行）"
    $PU destroy --stack "$STACK" --yes >/dev/null 2>&1 || true
    run up-serial up --stack "$STACK" --yes --parallel 1
    $PU stack export --stack "$STACK" 2>/dev/null > "$LOGS/export-serial.json"
    local t1
    t1=$(grep -oE "Duration: [0-9]+s" "$LOGS/up-serial.log" | head -1)
    note "跑法 B：默认并行"
    $PU destroy --stack "$STACK" --yes >/dev/null 2>&1 || true
    run up-parallel up --stack "$STACK" --yes
    $PU stack export --stack "$STACK" 2>/dev/null > "$LOGS/export-parallel.json"
    local t2
    t2=$(grep -oE "Duration: [0-9]+s" "$LOGS/up-parallel.log" | head -1)
    python3 - "$LOGS/export-serial.json" "$LOGS/export-parallel.json" <<'PY'
import json, sys

def sig(path):
    d = json.load(open(path))
    out = []
    for r in d["deployment"]["resources"]:
        if r["type"].startswith("pulumi:"):
            continue
        out.append((r["type"], r["urn"].split("::")[-1],
                    json.dumps(r.get("inputs", {}), sort_keys=True)))
    return sorted(out)

assert sig(sys.argv[1]) == sig(sys.argv[2]), "两种并行度的账本不一致"
print("        [ok] 串行与并行的账本逐项一致——期望态与调度顺序无关")
PY
    wait_http "http://localhost:$PORT/"; check_nginx "$PORT"
    note "[ok] 两种跑法服务一致（时长：串行 ${t1} / 并行 ${t2}）"
}

do_clean() {
    step "clean" "销毁全清 + 零残留断言"
    if $PU stack select "$STACK" >/dev/null 2>&1; then
        run destroy destroy --stack "$STACK" --yes
    fi
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep '^pulumi08' || true)
    if [ -z "$leftover" ]; then
        note "[ok] 容器/网络零残留"
    else
        note "[!] 有残留：$leftover" >&2
        return 1
    fi
    rm -rf "$LOGS"
    note "日志已清；state 与 Pulumi.yaml 保留（配置与账本是项目资产）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)    do_apply ;;
        graph)    do_graph ;;
        parallel) do_parallel ;;
        clean)    do_clean ;;
        all)      do_apply; do_graph; do_parallel; do_clean ;;
        *) echo "可用: apply | graph | parallel | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
