#!/usr/bin/env bash
# publish_artifact.sh —— bitstream 制品的版本化发布（不可变守卫 + cosign 签名 + urllib 上传）
# 用法：publish_artifact.sh <top.bin> <version>
# 依赖：cosign（CI 用 eda-base:1.1 内置；本地用 brew/仓库内二进制）、python3
set -euo pipefail

# CI 容器内 localhost 不是 GitLab：runner network_mode 使 job 容器可达 gitlab 别名
if [ -n "${CI_JOB_ID:-}" ]; then
    URL="http://gitlab"
else
    URL="${GITLAB_URL:-http://localhost:28200}"
fi
PROJECT="semi%2Feda-base"
PACKAGE="rtl-gcd-bitstream"
BIN="${1:?用法: publish_artifact.sh <top.bin> <version>}"
VER="${2:?用法: publish_artifact.sh <top.bin> <version>}"
API="$URL/api/v4/projects/$PROJECT/packages/generic/$PACKAGE/$VER"

sha256sum() { shasum -a 256 "$@" 2>/dev/null || command sha256sum "$@"; }

# ── 不可变守卫：HEAD 探测制品文件（200 = 已发布，拒绝覆盖）──
probe=$(python3 - "$API/top.bin" <<'PY'
import os, sys, urllib.request, urllib.error
r = urllib.request.Request(sys.argv[1], method="HEAD")
r.add_header("PRIVATE-TOKEN", os.environ.get("GITLAB_PAT", ""))
try:
    with urllib.request.urlopen(r, timeout=15) as resp:
        print(resp.status)
except urllib.error.HTTPError as e:
    print(e.code)
PY
)
if [ "$probe" = "200" ]; then
    echo "[publish] 拒绝：版本 $VER 已存在（制品不可变——换新版本号，别覆盖）"
    exit 1
fi

work=$(mktemp -d)
cp "$BIN" "$work/top.bin"
sha256sum "$work/top.bin" | awk '{print $1"  top.bin"}' > "$work/MANIFEST.sha256"

# ── cosign 就绪：系统优先（1.1 内置），回退仓库内二进制（LFS 指针则定点拉取）──
if ! command -v cosign >/dev/null 2>&1; then
    COSIGN_BIN="$(dirname "$0")/cosign"
    if head -1 "$COSIGN_BIN" 2>/dev/null | grep -q "git-lfs"; then
        git config "lfs.url" "http://gitlab-ci-token:${CI_JOB_TOKEN:-x}@gitlab/semi/ip/design/rtl-gcd.git/info/lfs" 2>/dev/null || true
        git lfs pull --include tools/cosign >/dev/null 2>&1 || true
    fi
    command -v cosign >/dev/null 2>&1 || { echo "[publish] cosign 不可用（LFS 拉取失败）"; exit 1; }
    export PATH="$(dirname "$COSIGN_BIN"):$PATH"
fi

# ── cosign 签名（v3 用 --signing-config；v2 用 --tlog-upload=false）──
SC="${COSIGN_SIGNING_CONFIG:-$HOME/.cosign/signing-config.json}"
if cosign sign-blob --help 2>&1 | grep -q "signing-config"; then
    SIG_FLAGS="--signing-config $SC"
else
    SIG_FLAGS="--tlog-upload=false"
fi
KEY="${COSIGN_KEY_FILE:-$HOME/.cosign/semi.key}"
COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" cosign sign-blob --key "$KEY" \
    $SIG_FLAGS --bundle "$work/top.bin.sig" "$work/top.bin" >/dev/null

echo "$work" > /tmp/publish_work_dir
cd "$work"

# ── urllib 上传（eda-base 无 curl；CI 带 CI_JOB_TOKEN、宿主带 GITLAB_PAT）──
export UPLOAD_BASE="$API"
export GITLAB_PAT="${GITLAB_PAT:-}"
for f in top.bin MANIFEST.sha256 top.bin.sig; do
    code=$(UPLOAD_FILE="$f" python3 - <<'PY'
import os, urllib.request
data = open(os.environ["UPLOAD_FILE"], "rb").read()
url = os.environ["UPLOAD_BASE"] + "/" + os.environ["UPLOAD_FILE"]
r = urllib.request.Request(url, data=data, method="PUT")
tok = os.environ.get("GITLAB_PAT")
job_tok = os.environ.get("CI_JOB_TOKEN")
if tok:
    r.add_header("PRIVATE-TOKEN", tok)
elif job_tok:
    r.add_header("JOB-TOKEN", job_tok)
with urllib.request.urlopen(r, timeout=120) as resp:
    print(resp.status)
PY
)
    if [ "$code" != "201" ]; then
        echo "[publish] 上传 $f 失败 HTTP $code"
        exit 1
    fi
    echo "[publish] $f -> 201"
done

echo "[publish] 完成：$PACKAGE $VER（bitstream+manifest+signature 三件套）"
