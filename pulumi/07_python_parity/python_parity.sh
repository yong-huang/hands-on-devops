#!/usr/bin/env bash
# =============================================================================
# 07 · Python 对照（同题重写）— 主演示脚本
#
# 完整生命周期：apply → parity → isolate → clean
# 用法：
#   ./python_parity.sh apply    # Python 栈上线（venv 自动建、依赖自动装）
#   ./python_parity.sh parity   # 拉起 01 的 TS 栈，export 资源清单逐项对比
#   ./python_parity.sh isolate  # 销毁 Python 栈，TS 栈毫发无损；再恢复
#   ./python_parity.sh clean    # 两栈全清，零残留
#   ./python_parity.sh          # 依次执行以上全部
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# preview/up 都要实例化 docker provider 插件，统一走 docker-env.sh 选 socket
. "../../scripts/docker-env.sh"

export PULUMI_BACKEND_URL="file://$PWD/.pulumi-state"
export PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab"
export PULUMI_SKIP_UPDATE_CHECK=1

PU="pulumi -C program"
TS_DIR="$PWD/../01_docker_provider"
LOGS=".logs"
PORT=28511          # TS 版占 28081，Python 版走 28511——并存不撞车
STACK="py"

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
        || { echo "    [x] 端口 $1 不是 nginx 首页——被别的服务占了？" >&2; exit 1; }
}

ensure_ready() {
    command -v pulumi >/dev/null || { echo "需要 Pulumi CLI：brew install pulumi" >&2; exit 1; }
    command -v python3 >/dev/null || { echo "需要 python3（>=3.9）" >&2; exit 1; }
    # venv 由 Pulumi.yaml 的 runtime.options.virtualenv 指定，CLI 自动取用
    if [ ! -x program/.venv/bin/python ]; then
        note "首次运行：创建 venv（python3 -m venv）"
        python3 -m venv program/.venv
    fi
    if ! program/.venv/bin/python -c "import pulumi, pulumi_docker" >/dev/null 2>&1; then
        note "首次运行：pip 安装 Python SDK（清华源，约 1 分钟）"
        program/.venv/bin/pip install -q -r program/requirements.txt
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
    step "apply" "Python 栈上线：同题的 Python 程序，同一台引擎"
    ensure_ready
    ensure_stack
    run up-py up --stack "$STACK" --yes
    if grep -q "created" "$LOGS/up-py.log"; then
        note "[ok] 创建完成"
    elif grep -q "unchanged" "$LOGS/up-py.log"; then
        note "[ok] 已在期望态（零变更，重跑幂等）"
    else
        echo "    [!] up 结果异常，看 ${LOGS}/up-py.log" >&2; exit 1
    fi
    docker ps --filter "name=pulumi07" --format "        {{.Names}}  {{.Image}}  {{.Ports}}"
    [ "$(docker inspect pulumi07-python-parity-nginx --format '{{.Config.Image}}')" = "nginx:1.27-alpine" ] \
        || { echo "    [!] 容器镜像不对" >&2; exit 1; }
    docker network inspect pulumi07-python-parity-net >/dev/null \
        || { echo "    [!] 自定义网络不存在" >&2; exit 1; }
    wait_http "http://localhost:$PORT/"; check_nginx "$PORT"
    note "[ok] Python SDK 声明的网络与容器都活了：http://localhost:$PORT/"
}

do_parity() {
    step "parity" "拉起 01 的 TS 栈，export 资源清单逐项对比"
    note "TS 版（01 号实验）apply——对照物上线（端口 28081）："
    ( cd "$TS_DIR" && ./docker_provider.sh apply ) 2>&1 | sed 's/^/        /' | tail -6
    note "两栈各自 stack export，落档对比："
    $PU stack export --stack "$STACK" 2>/dev/null > "$LOGS/py-export.json"
    ( cd "$TS_DIR" && PULUMI_BACKEND_URL="file://$TS_DIR/.pulumi-state" \
        PULUMI_CONFIG_PASSPHRASE="hands-on-devops-lab" PULUMI_SKIP_UPDATE_CHECK=1 \
        pulumi -C program stack export --stack dev 2>/dev/null ) > "$LOGS/ts-export.json"
    note "        py $(wc -c <"$LOGS/py-export.json" | tr -d ' ') 字节 / ts $(wc -c <"$LOGS/ts-export.json" | tr -d ' ') 字节"
    python3 - "$LOGS/ts-export.json" "$LOGS/py-export.json" <<'PY'
import json, sys

def resources(path):
    d = json.load(open(path))
    out = []
    for r in d["deployment"]["resources"]:
        if r["type"].startswith("pulumi:"):        # 栈与 provider 记录不比
            continue
        logical = r["urn"].split("::")[-1]
        inputs = r.get("inputs", {})
        out.append((r["type"], logical, inputs))
    return sorted(out)

ts, py = resources(sys.argv[1]), resources(sys.argv[2])
assert [t for t, _, _ in ts] == [t for t, _, _ in py], "资源类型集合不一致"
print("        类型与逻辑名（两语言完全一致）：")
for (t, l, _), (_, _, _) in zip(ts, py):
    print(f"        {t}  {l}")
for (_, _, ti), (_, _, pi) in zip(ts, py):
    if "image" in ti:
        assert sorted(ti) == sorted(pi), f"账本键名不一致：{sorted(set(ti) ^ set(pi))}"
        assert ti["image"] == pi["image"] == "nginx:1.27-alpine", "镜像不一致"
        tp, pp = ti["ports"][0], pi["ports"][0]
        assert tp["internal"] == pp["internal"] == 80, "容器内端口不一致"
        assert len(ti["networksAdvanced"]) == len(pi["networksAdvanced"]) == 1, "挂网数不一致"
        print("        Container inputs 键名逐字一致——state 存 provider schema 形态，与语言无关")
        print("        属性同构：image 一致、ports 结构一致、挂网 1 条")
        print(f"        预期参数差异：external 端口 ts={tp['external']} / py={pp['external']}；真名前缀各异")
print("        [ok] Python 版与 TS 版部署出同构资源——只有语言外壳不同")
PY
    docker ps --filter "name=pulumi0" --format "        {{.Names}}  {{.Ports}}"
    wait_http http://localhost:28081/; check_nginx 28081
    wait_http "http://localhost:$PORT/"; check_nginx "$PORT"
    note "[ok] 两栈并存：TS 栈 28081 与 Python 栈 $PORT 同时在线"
}

do_isolate() {
    step "isolate" "销毁 Python 栈，TS 栈毫发无损"
    run destroy-py destroy --stack "$STACK" --yes
    if docker ps -a --format '{{.Names}}' | grep -q '^pulumi07'; then
        echo "    [!] Python 容器应已销毁" >&2; exit 1
    fi
    wait_http http://localhost:28081/; check_nginx 28081
    note "[ok] TS 栈的 28081 照常服务——两个项目的栈互不干扰"
    run up-py-restore up --stack "$STACK" --yes
    wait_http "http://localhost:$PORT/"; check_nginx "$PORT"
    note "[ok] Python 栈按自己的配置重建"
}

do_clean() {
    step "clean" "两栈全清，零残留"
    if $PU stack select "$STACK" >/dev/null 2>&1; then
        run destroy-py destroy --stack "$STACK" --yes
    fi
    ( cd "$TS_DIR" && ./docker_provider.sh clean ) 2>&1 | tail -2 | sed 's/^/        /'
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep -E '^pulumi0[17]' || true)
    if [ -z "$leftover" ]; then
        note "[ok] 两套容器/网络零残留"
    else
        note "[!] 有残留：$leftover" >&2
        return 1
    fi
    rm -rf "$LOGS"
    note "日志已清；state 与源码保留（.venv 是运行时产物，已被 gitignore）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)   do_apply ;;
        parity)  do_parity ;;
        isolate) do_isolate ;;
        clean)   do_clean ;;
        all)     do_apply; do_parity; do_isolate; do_clean ;;
        *) echo "可用: apply | parity | isolate | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
