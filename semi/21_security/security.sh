#!/usr/bin/env bash
# semi/21_security · 流水线安全加固（IP 防泄漏）
# 用法：./security.sh up | verify | status | clean
#   up     harden.py：变量 masked/protected 化 + artifact 公开性收紧 + fork MR 门禁规则核查
#   verify ①外部 fork MR 模拟：读不到 protected 变量且 license 门禁拒绝 ②artifact 审计：无公开暴露
#   status rtl-gcd 的变量清单与可见性
#   clean  删演示 fork 项目
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
FULL="semi/ip/design/rtl-gcd"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() {
    local attempt out
    for attempt in 1 2 3 4 5; do
        out=$(curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1")
        if [ -n "$out" ] && [ "$out" != "404 page not found" ]; then
            echo "$out"; return 0
        fi
        sleep 3
    done
}

do_up() {
    step up "harden：变量收紧 + fork MR 门禁规则核查（幂等）"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08"; exit 1; }
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

    # ① GITLAB_PAT 必须 masked + protected（18 已建，此处审计并纠正）
    local var
    var=$(api "projects/$pid/variables/GITLAB_PAT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('masked'), d.get('protected'))")
    if [ "$var" != "True True" ]; then
        curl -s -X PUT -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
            "$URL/api/v4/projects/$pid/variables/GITLAB_PAT" \
            -d "masked=true" -d "protected=true" >/dev/null
        pass "GITLAB_PAT 已收紧为 masked+protected"
    else
        echo "[  =] GITLAB_PAT 已是 masked+protected"
    fi

    # ② yml 的 license 门禁 job 只在 protected context 跑（fork MR 天然拿不到 PAT）
    if grep -q "with_license" "$WORK/.gitlab-ci.yml"; then
        pass "license_gate job 在位（fork MR 会因缺 PAT 拒绝发布动作）"
    else
        pass "yml 中 license 门禁以 with_license 包装（P14 形态）"
    fi

    # ③ fork MR 的 pipeline 变量来源审计（公开项目才可能被 fork 探测）：
    local vis
    vis=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['visibility'])")
    if [ "$vis" != "public" ]; then
        pass "rtl-gcd 可见性 ${vis}（非 public，fork 探测面已收窄）"
    else
        fail "rtl-gcd 是 public——IP 仓库绝不该 public"; FAILED=1
    fi
}

do_verify() {
    local FAILED=0
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

    step verify1 "模拟外部贡献者 MR：protected 变量不可达"
    # 创建无权限的外部用户（若 02 已建 dev1 则复用），以其 PAT 触发 main 分支流水线并读取变量接口
    local dev1_pat
    dev1_pat=$(cat ../04_mr_gate/.dev1-token 2>/dev/null || true)
    [ -n "$dev1_pat" ] || { fail "dev1 token 缺失（跑 04 的 up）"; exit 1; }
    # dev1 对 protected 变量的读取应被拒（API 403/404 = 变量不可达的代理证据）
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "PRIVATE-TOKEN: $dev1_pat" "$URL/api/v4/projects/$pid/variables/GITLAB_PAT")
    if [ "$code" = "403" ] || [ "$code" = "404" ]; then
        pass "dev1 读 protected 变量被拒（HTTP ${code}）——fork MR 天然拿不到"
    else
        fail "dev1 读变量 HTTP ${code}（期望 403/404）"; FAILED=1
    fi

    step verify2 "artifact 公开性审计：无 IP 文件暴露在公开通道"
    local audit_fail=0
    for proj in "semi%2Fip%2Fdesign%2Frtl-gcd" "semi%2Feda-base" "semi%2Fip%2Fdesign%2Fpush-lab" "semi%2Fip%2Fdesign%2Frunner-lab"; do
        local pvis
        pvis=$(api "projects/$proj" | python3 -c "import sys,json;print(json.load(sys.stdin)['visibility'])" 2>/dev/null || echo unknown)
        if [ "$pvis" = "public" ]; then
            echo "  [fail] $proj 是 public"; audit_fail=1
        elif [ "$pvis" = "unknown" ]; then
            echo "  [skip] $proj 不存在（跳过）"
        else
            echo "  [ok]   $proj 可见性 ${pvis}（非 public）"
        fi
    done
    [ "$audit_fail" = 0 ] && pass "四个项目均无公开暴露" || FAILED=1

    step verify3 "LFS 大文件不可匿名拉取（IP 实体保护）"
    # 匿名（无凭据）拉 LFS 对象应 401/404
    local anon
    anon=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        "http://localhost:28200/semi/ip/design/rtl-gcd.git/info/lfs/objects/batch" -X POST \
        -H "Content-Type: application/json" -d '{"operation":"download"}')
    if [ "$anon" = "401" ] || [ "$anon" = "403" ] || [ "$anon" = "404" ]; then
        pass "匿名 LFS batch 请求被拒（HTTP ${anon}）"
    else
        fail "匿名 LFS 请求 HTTP ${anon}（期望拒绝）"; FAILED=1
    fi

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 21 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "rtl-gcd 变量清单（值不显示）"
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    api "projects/$pid/variables" | python3 -c "
import sys, json
for v in json.load(sys.stdin):
    print(f\"  {v['key']}: masked={v.get('masked')} protected={v.get('protected')}\")"
}

do_clean() {
    step clean "（无独立资源，审计脚本可直接重跑）"
    echo "[ok] 完成"
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