#!/usr/bin/env bash
# =============================================================================
# 31 · act 本地回路与 workflow 语法深潜 — 主演示脚本
#
# act 把 GitHub Actions 的 runner 搬进本机 Docker：-W 指定 workflow、
# --pull=false 强制用本地镜像（离线确定性）、--artifact-server-path 落盘制品。
#
# ./act_basics.sh apply    10 个语法特性 workflow 逐个跑，逐条断言
# ./act_basics.sh observe  看制品落盘、日志取证、镜像预算
# ./act_basics.sh fail     破坏注入：篡改→md5 红、超预算→被杀、断路→下游跳
# ./act_basics.sh clean    清理本地产物
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

IMG="catthehacker/ubuntu:act-latest"
ART=".artifacts"
LOGS=".logs"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

# 公共 act 参数：镜像钉死 + 离线 + 制品服务落盘到实验目录
ACT=(act --pull=false -P "ubuntu-latest=$IMG" --artifact-server-path "$ART")

# run_wf <file> [extra...]：跑一个 workflow，日志留档，退出码透传（pipefail 下 tee 不吞错）
run_wf() {
    local f="$1"; shift
    mkdir -p "$LOGS"
    "${ACT[@]}" -W "$f" "$@" 2>&1 | tee "$LOGS/$(basename "$f" .yml).log"
}

# expect_ok <file> <grep断言> [extra...]：跑通且日志文件命中关键标记
# 坑：不要在活管道上 grep -q——它命中即退出，会把 tee 挤成 SIGPIPE，
#     pipefail 下偶发"明明全绿却断言失败"。所以先跑完留档，再对文件断言。
expect_ok() {
    local f="$1" marker="$2"; shift 2
    local name; name="$(basename "$f" .yml)"
    run_wf "$f" "$@" # 退出码透传：act 红 → 这里就红
    grep -q "$marker" "$LOGS/$name.log" \
        || { echo "    [!] $name 未命中断言 [$marker]" >&2; exit 1; }
    note "[ok] ${name}：$marker" # 坑②：$var 后紧跟 CJK 全角字符要加 {}，否则字节被并入变量名
}

do_apply() {
    step "apply" "10 个语法特性逐个跑（首次约 1 分钟，之后秒级）"

    expect_ok workflows/01_needs.yml        "NEEDS-OK"
    expect_ok workflows/02_if.yml           "IF-OK"
    expect_ok workflows/03_timeout.yml      "TIMEOUT-OK"
    expect_ok workflows/04_concurrency.yml  "CONCURRENCY-OK"
    expect_ok workflows/05_artifact.yml     "MD5-OK"

    # secrets：-s 注入（等价于仓库 Settings → Secrets），日志必须只见 *** 且原值零泄漏
    expect_ok workflows/06_secrets.yml "SECRETS-OK" -s TOKEN=super-secret-42
    grep -q 'token=\*\*\*' "$LOGS/06_secrets.log" \
        || { echo "    [!] 日志未打码" >&2; exit 1; }
    if grep -q 'super-secret-42' "$LOGS/06_secrets.log"; then
        echo "    [!] 原值泄漏进日志" >&2; exit 1
    fi
    note "[ok] 06_secrets：日志层打码、原值零泄漏"

    expect_ok workflows/07_context.yml "CONTEXT-OK"
    expect_ok workflows/08_matrix.yml  "py=3.11 variant=slim"
    grep -q 'py=3.12 variant=full' "$LOGS/08_matrix.log" \
        || { echo "    [!] 矩阵组合不全" >&2; exit 1; }
    note "[ok] 08_matrix：2×2 四个组合全部执行"

    expect_ok workflows/09_defaults.yml "DEFAULTS-OK"
    expect_ok workflows/10_outputs.yml  "OUTPUTS-OK"

    note "10/10 语法特性全绿，本地迭代回路成立"
}

do_observe() {
    step "observe" "本地产物与镜像预算"
    note "制品服务落盘目录 ${ART}（upload-artifact 的 zip 都在这）："
    find "$ART" -type f | head -5 | sed 's/^/          /'
    note "workflow 运行日志（断言取证的原始出处）："
    ls "$LOGS" | sed 's/^/          /'
    note "job 容器镜像（离线回路的固定成本）："
    docker image inspect "$IMG" --format '          {{.Os}}/{{.Architecture}}  {{.Size}}'
}

do_fail() {
    step "fail" "破坏注入①——篡改制品，md5 断言必须拦住"
    if run_wf workflows/05_artifact.yml --env TAMPER=1; then
        echo "    [!] 篡改后竟然全绿" >&2; exit 1
    fi
    grep -q 'FAILED' "$LOGS/05_artifact.log" \
        || { echo "    [!] 篡改未被检出" >&2; exit 1; }
    note "[ok] 篡改被 md5sum -c 抓住，job 转红"

    step "fail" "破坏注入②——超预算 job 被强杀（step 层 timeout，秒级）"
    if run_wf workflows/90_timeout_kill.yml; then
        echo "    [!] 超预算竟然全绿，击杀没生效" >&2; exit 1
    fi
    grep -q 'TIMEOUT-KILLED' "$LOGS/90_timeout_kill.log" \
        || { echo "    [!] 未见到击杀取证标记（124）" >&2; exit 1; }
    note "[ok] 预算到点强杀（exit 124 取证），act 非 0 退出"

    step "fail" "破坏注入③——needs 断路器：上游红，test 被跳过，验尸官照跑"
    if run_wf workflows/91_needs_fail.yml; then
        echo "    [!] 断了链还全绿" >&2; exit 1
    fi
    if grep -q 'TEST-JOB-RAN' "$LOGS/91_needs_fail.log"; then
        echo "    [!] test 没被断路，竟然执行了" >&2; exit 1
    fi
    grep -q 'REPORT-OK' "$LOGS/91_needs_fail.log" \
        || { echo "    [!] always() 验尸官没跑，语义不对" >&2; exit 1; }
    note "[ok] test 被 skip（零执行痕迹），report 靠 always() 验尸（GitHub 语义忠实还原）"
}

do_clean() {
    step "clean" "清理本地产物"
    rm -rf "$ART" "$LOGS"
    note "[ok] $ART $LOGS 已清（job 容器由 act 自动回收，无残留）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply)   do_apply ;;
        observe) do_observe ;;
        fail)    do_fail ;;
        clean)   do_clean ;;
        all)     do_apply; do_observe; do_fail; do_clean ;;
        *) echo "可用: apply | observe | fail | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
