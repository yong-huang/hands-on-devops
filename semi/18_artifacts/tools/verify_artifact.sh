#!/usr/bin/env bash
# verify_artifact.sh —— 制品消费端校验：下载 → sha256 对 manifest → cosign 验签
# 用法：verify_artifact.sh <version>   （全过打印 [ok]，任何一环失败非零退出）
set -euo pipefail

URL="${GITLAB_URL:-http://localhost:28200}"
AUTH="PRIVATE-TOKEN: ${GITLAB_PAT:?需要 GITLAB_PAT}"
PROJECT="semi%2Feda-base"
PACKAGE="rtl-gcd-bitstream"
VER="${1:?用法: verify_artifact.sh <version>}"
API="$URL/api/v4/projects/$PROJECT/packages/generic/$PACKAGE/$VER"

work=$(mktemp -d)
for f in top.bin MANIFEST.sha256 top.bin.sig; do
    code=$(curl -s -o "$work/$f" -w '%{http_code}' --max-time 120 -H "$AUTH" "$API/$f")
    [ "$code" = "200" ] || { echo "[verify] 下载 $f 失败 HTTP $code"; exit 1; }
done

# 1) sha256 与发布清单一致
cd "$work"
actual=$(shasum -a 256 top.bin | awk '{print $1}')
want=$(awk '{print $1}' MANIFEST.sha256)
[ "$actual" = "$want" ] || { echo "[verify] sha256 不匹配：$actual != $want"; exit 1; }
echo "[verify] sha256 一致：${actual:0:16}…"

# 2) cosign 验签
COSIGN_PASSWORD="" cosign verify-blob --key "${COSIGN_KEY:-$HOME/.cosign/semi}.pub" \
    --bundle top.bin.sig --insecure-ignore-tlog top.bin >/dev/null &&
    echo "[verify] cosign 验签通过" || { echo "[verify] 验签失败"; exit 1; }

echo "[ok] 制品 $PACKAGE $VER 三重校验通过（下载/sha256/签名）"
