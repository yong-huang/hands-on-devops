#!/usr/bin/env bash
# =============================================================================
# 22 · 策略即代码（OPA/Conftest）— 主演示脚本
#
# Rego 声明安全基线 → conftest 门禁：策略单测（verify）→ 合规通过 → 违规拦截
# （逐类断言）→ 多文档 YAML → warn 不阻断的分层语义 → CI 门禁模拟。
#
# ./conftest_policy.sh policies   展示策略集（Rego 即代码，可 review 可 diff）
# ./conftest_policy.sh verify     策略自身的单元测试（conftest verify）
# ./conftest_policy.sh pass       合规部署通过（退出码 0）
# ./conftest_policy.sh deny       逐类违规被拦截（退出码 1 + 指明 deny 消息）
# ./conftest_policy.sh yaml       多文档 YAML：一个违规 = 整体失败
# ./conftest_policy.sh warn       warn 层告警不阻断（分层语义）
# ./conftest_policy.sh gate       CI 门禁模拟：违规部署必须被挡下
# ./conftest_policy.sh clean      清理
# ./conftest_policy.sh            # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

P=policies
F=fixtures
LOGS=.logs

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }
ok()   { echo "        ✅ $1"; }

must_contain() {  # must_contain <file> <pattern> <说明>
    grep -qE "$2" "$1" || fail "$3（$1 缺少 /$2/）"
    ok "$3"
}

# CI 门禁函数：conftest 退出码非 0 = 违规 = 阻断（CI 里等价于 pipeline fail）
gate() {  # gate <fixture>
    conftest test "$1" -p "$P" >/dev/null 2>&1
}

do_policies() {
    step policies "策略集（Rego 即代码——可 review、可 diff、可测试）"
    for f in "$P"/*.rego; do
        case "$(basename "$f")" in *_test.rego) continue ;; esac
        note "· $(basename "$f")：$(grep -cE '^deny contains' "$f") deny / $(grep -cE '^warn contains' "$f") warn"
    done
}

do_verify() {
    step verify "策略自身的单元测试（策略是代码，代码要有测试）"
    mkdir -p "$LOGS"
    conftest verify -p "$P" 2>&1 | tee "$LOGS/verify.log"
    must_contain "$LOGS/verify.log" "5 tests, 5 passed" "策略单测 5/5 全绿"
}

do_pass() {
    step pass "合规部署通过（退出码 0）"
    local rc=0
    conftest test "$F/good-deployment.json" -p "$P" 2>&1 | tee "$LOGS/pass.log" || rc=$?
    [ "$rc" = "0" ] || fail "合规部署应通过（rc=${rc}）"
    must_contain "$LOGS/pass.log" "6 passed, 0 warnings, 0 failures" "合规部署 6 项全过（5 deny + 1 warn 规则集）"
    ok "退出码 0 —— CI 门禁放行"
}

do_deny() {
    step deny "逐类违规被拦截（每类断言退出码 1 + 具体 deny 消息）"
    local rc=0
    conftest test "$F/bad-deployment.json" -p "$P" 2>&1 | tee "$LOGS/deny-latest.log" || rc=$?
    [ "$rc" = "1" ] || fail "违规部署退出码应为 1，实为 $rc"
    must_contain "$LOGS/deny-latest.log" "uses :latest tag" "拦截：:latest 镜像"
    must_contain "$LOGS/deny-latest.log" "has no resource limits" "拦截：无资源限制"

    rc=0
    conftest test "$F/bad-privileged.json" -p "$P" 2>&1 | tee "$LOGS/deny-privileged.log" || rc=$?
    [ "$rc" = "1" ] || fail "特权容器退出码应为 1，实为 $rc"
    must_contain "$LOGS/deny-privileged.log" "must not run privileged" "拦截：特权容器"

    rc=0
    conftest test "$F/missing-labels.json" -p "$P" 2>&1 | tee "$LOGS/deny-labels.log" || rc=$?
    [ "$rc" = "1" ] || fail "缺 label 退出码应为 1，实为 $rc"
    must_contain "$LOGS/deny-labels.log" "missing required label 'app'" "拦截：缺 app label"
    must_contain "$LOGS/deny-labels.log" "missing required label 'team'" "拦截：缺 team label"
}

do_yaml() {
    step yaml "多文档 YAML：一个违规 = 整体失败（conftest 逐文档求值）"
    local rc=0
    conftest test "$F/batch.yaml" -p "$P" 2>&1 | tee "$LOGS/yaml.log" || rc=$?
    [ "$rc" = "1" ] || fail "多文档含违规应整体失败（rc=${rc}）"
    must_contain "$LOGS/yaml.log" "uses :latest tag" "违规文档被点名"
    must_contain "$LOGS/yaml.log" "11 passed, 0 warnings, 1 failure" "12 项 = 6 规则 × 2 文档，只拦违规的那个"
    ok "整体 rc=1（门禁语义：一票否决）"
}

do_warn() {
    step warn "warn 层告警不阻断（deny=红线 warn=建议的分层语义）"
    local rc=0
    conftest test "$F/warn-only.json" -p "$P" 2>&1 | tee "$LOGS/warn.log" || rc=$?
    [ "$rc" = "0" ] || fail "仅 warn 的部署不应被阻断（rc=${rc}）"
    must_contain "$LOGS/warn.log" "does not run as non-root" "warn 消息可见（提醒但不拦）"
    ok "warn 不影响退出码（rc=0）——分层：deny 阻断，warn 提醒"
}

do_gate() {
    step gate "CI 门禁模拟：违规部署必须被挡下，合规才能继续"
    if gate "$F/bad-deployment.json"; then
        fail "门禁放行了违规部署（不可能发生）"
    fi
    ok "违规部署被门禁挡下（rc=1 → pipeline fail）"
    if gate "$F/good-deployment.json"; then
        ok "合规部署过闸（rc=0 → pipeline 继续）"
    else
        fail "门禁误杀合规部署"
    fi
}

do_clean() {
    step clean "清理日志"
    rm -rf "$LOGS"
    note "[ok] 零残留"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        policies) do_policies ;;
        verify)   do_verify ;;
        pass)     do_pass ;;
        deny)     do_deny ;;
        yaml)     do_yaml ;;
        warn)     do_warn ;;
        gate)     do_gate ;;
        clean)    do_clean ;;
        all)
            do_policies
            do_verify
            do_pass
            do_deny
            do_yaml
            do_warn
            do_gate
            do_clean
            echo; echo "✅ 22 全部通过"
            ;;
        *) echo "可用: policies | verify | pass | deny | yaml | warn | gate | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
