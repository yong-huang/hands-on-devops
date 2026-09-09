#!/usr/bin/env bash
# =============================================================================
# 07 · Molecule — 主演示脚本
#
# role 有了测试：molecule test 绿是常态；本脚本还演示"故意写坏 role → 测试变红"。
# ./molecule_testing.sh test    完整测试（create→converge→幂等→verify→destroy）
# ./molecule_testing.sh break   注入坏配置 → 测试变红 → 修复 → 回绿
# ./molecule_testing.sh clean   清理 molecule 残留实例
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

ROLE="roles/webconf"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

do_test() {
    step "test" "molecule test：五幕全套（第一次跑会拉镜像，稍慢）"
    ( cd "$ROLE" && molecule test )
    note "[ok] 测试全绿：语法/创建/收敛/幂等/验证/销毁 全部 Successful"
}

do_break() {
    step "break" "故意写坏 role（端口 8080→8081，verify 断言将失败）"
    mkdir -p tmp
    cp "$ROLE/templates/app.conf.j2" tmp/app.conf.j2.bak
    LC_ALL=C sed -i '' 's/listen 8080/listen 8081/' "$ROLE/templates/app.conf.j2"

    note "跑测试（预期 verify 阶段红灯）"
    local rc=0
    ( cd "$ROLE" && molecule test ) > tmp/break.log 2>&1 || rc=$?
    if [ $rc -ne 0 ] && grep -qE "assert|FAILED" tmp/break.log; then
        note "[检出] 测试变红（exit=${rc}：断言抓住 'listen 8080' 缺失"
        grep -m1 -B1 "assert" tmp/break.log | LC_ALL=C sed 's/^/        /' | head -3 || true
    else
        note "[x] 预期红灯未出现（rc=${rc}）" >&2
    fi

    step "break" "还原 role → 测试回绿（这就是 CI 里的修复闭环）"
    cp tmp/app.conf.j2.bak "$ROLE/templates/app.conf.j2"
    ( cd "$ROLE" && molecule test ) > tmp/fix.log 2>&1
    note "[ok] 修复后回绿（SCENARIO RECAP failed=0，见 tmp/fix.log）"
}

do_clean() {
    step "clean" "销毁测试实例并清理临时文件"
    ( cd "$ROLE" && molecule destroy ) >/dev/null 2>&1 || true
    rm -rf tmp
    local leftover
    leftover=$(docker ps -a --format '{{.Names}}' | grep -i 'webconf-instance' || true)
    [ -z "$leftover" ] && note "[ok] 测试容器零残留" || { note "[!] 残留：$leftover" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        test)  do_test ;;
        break) do_break ;;
        clean) do_clean ;;
        all)   do_test; do_break; do_clean ;;
        *) echo "可用: test | break | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
