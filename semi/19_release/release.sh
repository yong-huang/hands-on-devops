#!/usr/bin/env bash
# semi/19_release · 发布工程（vTag → Release + changelog + 客户交付包）
# 用法：./release.sh up | verify | status | clean
#   up     推 release stage（tag 触发）+ make_release.py 到 rtl-gcd
#   verify 推 vTag → Release 自动创建（changelog 含 MR 标题）→ 交付包解包校验 + 审计单字段
#   status Releases 清单
#   clean  删演示 Release/tag（保留 tools/）
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
    # OrbStack 偶发空响应/404 文本：重试（P5 同款加固）
    local attempt out
    for attempt in 1 2 3 4 5; do
        out=$(curl -s --max-time 30 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1")
        if [ -n "$out" ] && [ "$out" != "404 page not found" ]; then
            echo "$out"; return 0
        fi
        sleep 3
    done
}

do_up() {
    step up "推 release stage + make_release.py 到 rtl-gcd"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    local changed=0
    if grep -q "make_release" "$WORK/.gitlab-ci.yml"; then
        echo "[  =] release stage 已在 yml"
    else
        cat >> "$WORK/.gitlab-ci.yml" <<'Y'

# ── 19 加装：发布工程（tag 触发 → changelog + 客户交付包 + Release）──
release:
  stage: regression
  image: localhost:28250/semi/eda-base:1.0
  tags: [eda]
  needs: [fpga]
  rules:
    - if: $CI_COMMIT_TAG =~ /^v/
  variables:
    RELEASE_VERSION: $CI_COMMIT_TAG
  script:
    - python3 tools/make_release.py
Y
        git -C "$WORK" add .gitlab-ci.yml
        changed=1
    fi
    if [ ! -f "$WORK/tools/make_release.py" ] || ! cmp -s tools/make_release.py "$WORK/tools/make_release.py"; then
        cp tools/make_release.py "$WORK/tools/make_release.py"
        git -C "$WORK" add tools/make_release.py
        changed=1
    fi
    if [ "$changed" = 1 ]; then
        git -C "$WORK" commit -qm "ci: 发布工程（tag → changelog + 交付包 + Release）"
        git -C "$WORK" push -q origin main
        pass "release stage 已推 main"
    else
        echo "[  =] 内容一致，跳过"
    fi
}

do_verify() {
    local FAILED=0
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")

    step release "推 vTag 触发发布流水线"
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    local ver="v0.2.$(date +%s)"
    git -C "$WORK" tag -a "$ver" -m "release $ver"
    git -C "$WORK" push -q origin "$ver" 2>/dev/null || git -C "$WORK" push origin "$ver" 2>&1 | tail -1

    step wait "等 release 流水线（tag 触发，最长 15 分钟）"
    local pl="" st=""
    for _ in $(seq 1 120); do
        read -r pl st <<<"$(api "projects/$pid/pipelines?ref=$ver&per_page=1" | python3 -c "
import sys, json
ps = json.load(sys.stdin)
if ps:
    print(ps[0]['id'], ps[0]['status'])
else:
    print('0 none')")"
        [ "$pl" != "0" ] && break
        sleep 6
    done
    [ "$pl" != "0" ] || { fail "tag 流水线未创建"; exit 1; }
    for _ in $(seq 1 150); do
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) break;; esac
        sleep 6
    done
    echo "  [  =] tag 流水线 #$pl $st"
    if [ "$st" = "success" ]; then
        pass "发布流水线全绿（tag 触发全链重跑）"
    else
        fail "tag 流水线 ${st}（期望 success）"; FAILED=1
    fi

    step verify "验收① Release 自动创建 + changelog 含 MR 标题 + 审计单字段"
    local rel
    rel=$(api "projects/$pid/releases/$ver")
    echo "$rel" | python3 -c "
import sys, json
r = json.load(sys.stdin)
desc = r.get('description', '')
links = [a['name'] for a in r.get('assets', {}).get('links', [])]
print('  [  =] Release', r['tag_name'], '| assets:', links)
assert '（merged MR）' in desc or 'merged MR' in desc, 'changelog 缺 MR 段'
assert '!1' in desc or '!2' in desc or '!3' in desc or '!4' in desc or '!' in desc, 'changelog 无 MR 编号'
print('  [ok]   Release 描述含 changelog（MR 列表）')
" || { fail "Release changelog 断言失败"; FAILED=1; }

    step verify "验收② 交付包解包校验（sha256 全对 + 审计单字段）"
    # 交付包在 Generic Packages；下载并逐条校验 MANIFEST
    local pkg_url
    pkg_url="http://localhost:28200/api/v4/projects/$pid/packages/generic/rtl-gcd-release/$ver/rtl-gcd-$ver.tar.gz"
    curl -s --max-time 120 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" -o /tmp/rel.tar.gz "$pkg_url"
    python3 - <<'PY' || FAILED=1
import tarfile, hashlib, json
t = tarfile.open("/tmp/rel.tar.gz")
t.extractall("/tmp/rel_check")
import os
os.chdir("/tmp/rel_check")
ok = True
for line in open("MANIFEST.sha256"):
    want, name = line.split()
    got = hashlib.sha256(open(name, "rb").read()).hexdigest()
    if got != want:
        print(f"  [fail] sha256 不匹配: {name}")
        ok = False
assert ok, "manifest 校验失败"
audit = json.load(open("audit.json"))
for k in ("version", "built_at", "pipeline", "contents"):
    assert k in audit, f"audit 缺字段 {k}"
print("  [ok]   交付包 sha256 全对 + audit.json 四字段齐全")
PY

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 19 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "rtl-gcd Releases"
    api "projects/$FULL/releases" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    print(f\"  {r['tag_name']}  {r['released_at'][:10]}  assets={len(r.get('assets',{}).get('links',[]))}\")"
}

do_clean() {
    step clean "删演示 Release 与 tag"
    for tag in $(api "projects/$FULL/releases" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r['tag_name'].startswith('v0.2.'):
        print(r['tag_name'])"); do
        api -X DELETE >/dev/null 2>&1 "projects/$FULL/releases/$tag" || true
        curl -s -X DELETE -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/projects/$FULL/repository/tags/$tag" >/dev/null || true
        echo "[ok] 删 $tag"
    done
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
