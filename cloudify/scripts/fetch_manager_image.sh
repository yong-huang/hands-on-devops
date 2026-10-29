#!/usr/bin/env bash
# =============================================================================
# 断点续传拉取 Cloudify AIO Manager 镜像（自救路径）
#
# 背景：镜像 ≥360MB 的大层经所有可用镜像源都会中途截断（short read / magic
# number mismatch），docker pull 不支持断点续传 → 换镜像源/换时段都过不去。
# 本脚本：走镜像源 v2 API（token 流程）→ 逐 blob 断点续传（curl -C -）→
# sha256 校验 → 组装 docker-archive → docker load。
#
# 用法：
#   fetch_manager_image.sh [tag] [arch]     # 默认 7.0.1 arm64
# 环境变量：
#   MIRROR      镜像源（默认 https://docker.1ms.run）
#   MAX_ROUNDS  单 blob 最大续传轮数（默认 300）
# =============================================================================
set -euo pipefail

TAG="${1:-7.0.1}"
ARCH="${2:-arm64}"
REPO="cloudifyplatform/community-cloudify-manager-aio"
IMAGE="${REPO}:${TAG}"
MIRROR="${MIRROR:-https://docker.1ms.run}"
MAX_ROUNDS="${MAX_ROUNDS:-300}"
WORK="${TMPDIR:-/tmp}/aio-fetch/${TAG}-${ARCH}"
ACC="application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json"

step() { echo; echo "=====> [$1] $2"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1"; exit 1; }

mkdir -p "$WORK/blobs" "$WORK/load"

TOKEN=$(curl -s -m 30 "${MIRROR}/openapi/v1/auth/token?scope=repository:${REPO}:pull&service=docker.1ms.run" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
[ -n "$TOKEN" ] || fail "token 获取失败"
ok "token 就绪（mirror 自带 realm）"

api() {  # api <accept> <path> <outfile>
    curl -s -m 60 -H "Authorization: Bearer $TOKEN" -H "Accept: $1" \
        "${MIRROR}/v2/${REPO}/${2}" -o "$3"
}

step manifest "取 index manifest 并选 ${ARCH}"
api "$ACC" "manifests/${TAG}" "$WORK/index.json"
DG=$(python3 -c "
import json
d = json.load(open('$WORK/index.json'))
ms = [m for m in d.get('manifests', []) if m.get('platform', {}).get('architecture') == '$ARCH']
print(ms[0]['digest'] if ms else '')")
[ -n "$DG" ] || fail "index 中没有 ${ARCH} manifest"
ok "$ARCH digest: ${DG:0:26}..."

step manifest "取平台 manifest（config + layers）"
api "application/vnd.docker.distribution.manifest.v2+json" "manifests/$DG" "$WORK/manifest.json"
python3 - "$WORK/manifest.json" > "$WORK/blobs.list" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(d["config"]["digest"], d["config"]["size"], "config")
for l in d["layers"]:
    print(l["digest"], l["size"], "layer")
EOF
ok "$(wc -l < "$WORK/blobs.list" | tr -d ' ') 个 blob"

fetch_blob() {  # fetch_blob <digest> <size>
    local digest="$1" want="$2" out="$WORK/blobs/$1" hex="${1#sha256:}" cur rounds=0
    while :; do
        cur=$(stat -f%z "$out" 2>/dev/null || echo 0)
        [ "$cur" -eq "$want" ] && break
        rounds=$((rounds + 1))
        [ "$rounds" -gt "$MAX_ROUNDS" ] && fail "blob ${digest:0:20} 超过 $MAX_ROUNDS 轮仍未完成（$cur/${want}）"
        # -C - 续传；307 跟随到 CDN（预签名 URL 无需 auth）；失败静默续传
        curl -sL --connect-timeout 15 --max-time 900 --retry 3 --retry-delay 2 \
            -C - -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" \
            -o "$out" "${MIRROR}/v2/${REPO}/blobs/${digest}" || true
        cur=$(stat -f%z "$out" 2>/dev/null || echo 0)
        echo "        round $rounds: ${digest:0:20}... $cur/$want ($(( cur * 100 / want ))%)"
        if [ "$cur" -gt "$want" ]; then
            fail "blob ${digest:0:20} 超写（$cur > ${want}），删除重下"
        fi
    done
    local got
    got=$(shasum -a 256 "$out" | awk '{print $1}')
    [ "$got" = "$hex" ] || { rm -f "$out"; fail "blob ${digest:0:20} sha256 不符（已删，重跑脚本重下）"; }
}

step download "逐 blob 断点续传 + sha256 校验"
while read -r digest size kind; do
    fetch_blob "$digest" "$size"
    ok "$kind ${digest:0:20}... ($(( size / 1024 / 1024 ))MB)"
done < "$WORK/blobs.list"

step assemble "组装 docker-archive 并 docker load"
CFG=$(awk '$3=="config"{print $1}' "$WORK/blobs.list")
CFG_HEX="${CFG#sha256:}"
cp "$WORK/blobs/$CFG" "$WORK/load/${CFG_HEX}.json"
python3 - "$WORK/blobs.list" "$WORK/load" "$CFG_HEX" "$IMAGE" <<'EOF'
import gzip, json, os, sys

blobs_list, load_dir, cfg_hex, image = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
layers = []
i = 0
for line in open(blobs_list):
    digest, size, kind = line.split()
    if kind != "layer":
        continue
    raw = os.path.join(load_dir, "..", "blobs", digest)
    dest = os.path.join(load_dir, "layer{}.tar".format(i))
    with gzip.open(raw, "rb") as src, open(dest, "wb") as dst:
        while True:
            chunk = src.read(1 << 20)
            if not chunk:
                break
            dst.write(chunk)
    layers.append("layer{}.tar".format(i))
    i += 1
manifest = [{"Config": cfg_hex + ".json", "RepoTags": [image], "Layers": layers}]
with open(os.path.join(load_dir, "manifest.json"), "w") as f:
    json.dump(manifest, f)
print("layers unpacked:", len(layers))
EOF
tar -C "$WORK/load" -cf "$WORK/image.tar" .
docker load -i "$WORK/image.tar"
ok "docker load 完成 → $IMAGE"
docker image inspect "$IMAGE" --format 'Loaded: {{.Id}} {{.Size}}'
