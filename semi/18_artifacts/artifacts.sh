#!/usr/bin/env bash
# semi/18_artifacts · 制品治理（bitstream 版本化 + 签名 + 不可变纪律）
# 用法：./artifacts.sh up | verify | status | clean
#   up     建 semi/eda-base 项目（制品宿主，若 06 已建则复用）+ 推 artifacts job 进 rtl-gcd
#   verify ①流水线内发布 v<ts> → 消费端三重校验过 ②重复发布同版本被拒（不可变）
#   status Packages 清单
#   clean  删演示包（eda-base 项目保留）
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
BR="artifacts-demo"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

do_up() {
    step up "推 artifacts job 到 rtl-gcd（幂等）"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    if grep -q "publish_artifact" "$WORK/.gitlab-ci.yml"; then
        echo "[  =] artifacts job 已在 yml"
        return 0
    fi
    cat >> "$WORK/.gitlab-ci.yml" <<'Y'

# ── 18 加装：制品治理（bitstream 发布+签名，消费端校验）──
publish_artifact:
  stage: regression
  needs: [fpga]
  image: localhost:28250/semi/eda-base:1.0
  tags: [eda]
  variables:
    GITLAB_PAT: ""          # 由 CI/CD 变量注入（masked+protected）
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  script:
    - bash tools/publish_artifact.sh syn/top.bin "ci-$CI_PIPELINE_ID"
Y
    mkdir -p "$WORK/tools"
    cp tools/publish_artifact.sh tools/verify_artifact.sh "$WORK/tools/"
    git -C "$WORK" add .gitlab-ci.yml tools/
    git -C "$WORK" commit -qm "ci: 制品治理（bitstream 版本化发布 + cosign 签名）"
    git -C "$WORK" push -q origin main
    pass "artifacts job 已推 main"
    # CI/CD 变量注入 PAT（masked；供 job 内 Generic Packages 上传鉴权）
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    local have
    have=$(api "projects/$pid/variables/GITLAB_PAT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('key',''))" 2>/dev/null || true)
    if [ "$have" = "GITLAB_PAT" ]; then
        echo "[  =] CI 变量 GITLAB_PAT 已存在"
    else
        curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
            "$URL/api/v4/projects/$pid/variables" \
            -d "key=GITLAB_PAT" -d "value=$(cat "$TOKEN_FILE")" \
            -d "masked=true" -d "protected=true" >/dev/null &&
            pass "CI/CD 变量 GITLAB_PAT 已注入（masked+protected）"
    fi
}

do_verify() {
    local FAILED=0
    local ts
    ts=$(date +%s)
    local ver="v$ts"
    # 从最近成功的 main 流水线取 bitstream（或本地流水线产物）
    step publish "发布 ${ver}（先查后传 + cosign 签名）"
    export GITLAB_PAT="$(cat "$TOKEN_FILE")"
    export GITLAB_URL="$URL"
    # bitstream 源：最近一次 success 流水线的 fpga job 归档
    local pid jid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    jid=$(python3 - "$pid" "$TOKEN_FILE" <<'PY'
import sys, gitlab
gl = gitlab.Gitlab("http://localhost:28200", private_token=open(sys.argv[2]).read().strip(), retry_transient_errors=True)
p = gl.projects.get(int(sys.argv[1]))
for pl in p.pipelines.list(ref="main", status="success", get_all=False, per_page=10):
    try:
        for j in p.pipelines.get(pl.id).jobs.list(get_all=True):
            if j.name == "fpga" and j.status == "success":
                print(j.id)
                raise SystemExit
    except SystemExit:
        raise
    except Exception:
        continue
PY
)
    [ -n "$jid" ] || { fail "找不到成功的 fpga job"; exit 1; }
    curl -s --max-time 180 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/jobs/$jid/artifacts" > /tmp/bitstream_art.zip
    local bin
    bin=$(python3 -c "
import zipfile
z = zipfile.ZipFile('/tmp/bitstream_art.zip')
n = [n for n in z.namelist() if n.endswith('.bin')][0]
open('/tmp/top.bin','wb').write(z.read(n))
print(n)")
    echo "  [  =] 源 bitstream：$bin"
    if bash tools/publish_artifact.sh /tmp/top.bin "$ver" 2>&1 | tee /tmp/pub.log | grep -q "三件套"; then
        pass "发布成功（bitstream+manifest+signature）"
    else
        fail "发布失败：$(tail -2 /tmp/pub.log)"; FAILED=1
    fi

    step verify1 "消费端三重校验（下载/sha256/cosign）"
    if bash tools/verify_artifact.sh "$ver" 2>&1 | tee /tmp/vfy.log | grep -q "\[ok\]"; then
        pass "$(grep '\[verify\]' /tmp/vfy.log | tr '\n' ' ')"
    else
        fail "校验失败：$(tail -2 /tmp/vfy.log)"; FAILED=1
    fi

    step verify2 "不可变纪律：同版本重复发布被拒"
    # 不用管道：pipefail 下 grep -q 提前退出会让发布脚本吃 SIGPIPE(141) 被误判
    bash tools/publish_artifact.sh /tmp/top.bin "$ver" > /tmp/dup.log 2>&1 || true
    if grep -q "拒绝" /tmp/dup.log; then
        pass "同版本二次发布被守卫拒绝（exit≠0 + 提示换版本号）"
    else
        fail "重复发布未被拒绝：$(tail -1 /tmp/dup.log)"; FAILED=1
    fi

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 18 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "semi/eda-base 的 Packages"
    api "projects/semi%2Feda-base/packages?per_page=5" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(f\"  {p['name']} {p['version']} ({p['package_type']})\")"
}

do_clean() {
    step clean "删演示包"
    for pid in $(api "projects/semi%2Feda-base/packages?per_page=50" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    if p['name'] == 'rtl-gcd-bitstream':
        print(p['id'])"); do
        api -X DELETE >/dev/null 2>&1 "projects/semi%2Feda-base/packages/$pid" || \
            curl -s -X DELETE -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
                "$URL/api/v4/projects/semi%2Feda-base/packages/$pid" >/dev/null
    done
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
