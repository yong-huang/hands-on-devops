#!/usr/bin/env bash
# 兜底拉取：镜像大层在国内镜像源反复断流时的可执行逃生门（README 坑 1 的脚本形态）
# 原理：daocloud 匿名 token → blob 请求 307 到 Cloudflare R2 签名 URL（支持 Range）→
#       15MB 小片顺序续传（整层大 range 会被边缘掐断）→ sha256 逐个校验 →
#       拼 OCI layout → docker load → 打 docker.1ms.run 与 gitlab 两个 tag
# 幂等：已校验过的 blob 直接跳过，中断后重跑即续传。首次全程实测约 40 分钟。
# 用法：./scripts/fallback_pull.sh          （成功后重跑 ./gitlab_up.sh up）
set -uo pipefail

WORK="${GITLAB_FALLBACK_WORK:-/tmp/gitlab_fallback}"
REF="docker.1ms.run/gitlab/gitlab-ce:latest"   # 只借它的 manifest；镜像本源是 Docker Hub gitlab/gitlab-ce
DC="https://docker.m.daocloud.io"
REPO="gitlab/gitlab-ce"
mkdir -p "$WORK"

log() { echo "==> [fallback] $1"; }

get_token() {
    curl -s --max-time 15 "$DC/auth/token?service=docker.m.daocloud.io&scope=repository:$REPO:pull" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('token') or d.get('access_token',''))" 2>/dev/null
}

tok=$(get_token)
[ -n "$tok" ] || { echo "拿不到 daocloud token（稍后重试或换网络）"; exit 1; }

# ── 1. 摸 manifest：借 docker manifest inspect 拿 arm64 原文（它自带认证流）──
manifest_json="$WORK/arm64_manifest.json"
if [ ! -s "$manifest_json" ]; then
    log "获取 arm64 manifest"
    docker manifest inspect --verbose "$REF" 2>/dev/null | python3 -c "
import sys, json, base64
for e in json.load(sys.stdin):
    p = (e.get('Descriptor') or {}).get('platform', {})
    if p.get('architecture') == 'arm64' and p.get('os') == 'linux':
        sys.stdout.write(base64.b64decode(e['Raw']).decode())
        break
" > "$manifest_json" || { echo "manifest 获取失败"; exit 1; }
fi

python3 - "$manifest_json" > "$WORK/layers.txt" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
print(m['config']['digest'], m['config']['size'])
for l in m['layers']:
    print(l['digest'], l['size'])
EOF

# ── 2. 单个小 blob 直下（≤50MB，带重试）──
fetch_small() {
    local digest="$1" hex="${1#sha256:}" out="$WORK/$hex" code i
    [ -s "$out" ] && return 0
    for i in 1 2 3 4 5; do
        code=$(curl -sL --max-time 300 --speed-time 20 --speed-limit 4096 -w '%{http_code}' \
               -H "Authorization: Bearer $tok" -o "$out" "$DC/v2/$REPO/blobs/$digest")
        [ "$code" = "200" ] && return 0
        sleep 3
    done
    echo "小层下载失败: $digest (HTTP $code)"; return 1
}

# ── 3. 大 blob：15MB 小片顺序续传（R2 上大 range 连接活不过 ~15-60MB）──
fetch_big() {
    local digest="$1" size="$2" hex="${1#sha256:}" out="$WORK/$hex" want have remaining send code
    [ -s "$out" ] && return 0
    # 每次循环前刷新签名 URL（一张 URL 约够一趟大传输，之后边缘会重置连接）
    local loc
    loc=$(curl -s -D - -o /dev/null --max-time 30 -r 0-1023 -H "Authorization: Bearer $tok" \
          "$DC/v2/$REPO/blobs/$digest" | grep -i '^location:' | tr -d '\r' | awk '{print $2}')
    [ -n "$loc" ] || { echo "拿不到签名 URL: $digest"; return 1; }
    have=0; [ -f "$out.part" ] && have=$(stat -f%z "$out.part")
    while [ "$have" -lt "$size" ]; do
        remaining=$(( have ))   # 整层从 0 下，绝对偏移即已有字节数
        send=$(( have + 15 * 1048576 - 1 )); [ "$send" -ge "$size" ] && send=$(( size - 1 ))
        code=$(curl -s --max-time 120 --speed-time 15 --speed-limit 8192 -w '%{http_code}' \
               -r "${remaining}-${send}" -o "$out.part.tmp" "$loc")
        if [ "$code" = "206" ]; then
            cat "$out.part.tmp" >> "$out.part"
        else
            echo "  HTTP $code at $(( have / 1048576 ))MB, sleep 5"
            sleep 5
        fi
        rm -f "$out.part.tmp"
        have=0; [ -f "$out.part" ] && have=$(stat -f%z "$out.part")
        echo "  大层: $(( have / 1048576 )) / $(( size / 1048576 )) MB"
    done
    mv "$out.part" "$out"
}

# ── 4. 逐个下载 + sha256 校验 ──
big_digest=$(sort -k2 -n -r "$WORK/layers.txt" | head -1 | awk '{print $1}')
big_size=$(sort -k2 -n -r "$WORK/layers.txt" | head -1 | awk '{print $2}')
while read -r digest size; do
    hex="${digest#sha256:}"; out="$WORK/$hex"
    actual=$(shasum -a 256 "$out" 2>/dev/null | awk '{print $1}')
    [ "$actual" = "$hex" ] && { echo "已就绪: ${hex:0:16}"; continue; }
    if [ "$digest" = "$big_digest" ]; then
        log "下载大层 ($(( size / 1048576 )) MB，小片续传)"
        fetch_big "$digest" "$size" || exit 1
    else
        log "下载小件 $(( size / 1024 ))KB"
        fetch_small "$digest" || exit 1
    fi
    actual=$(shasum -a 256 "$out" | awk '{print $1}')
    [ "$actual" = "$hex" ] || { echo "sha256 不匹配: $hex"; exit 1; }
done < "$WORK/layers.txt"
log "全部 blob sha256 校验通过"

# ── 5. 拼 OCI layout → docker load → 双 tag ──
log "拼装 OCI layout 并 docker load"
LAYOUT="$WORK/oci"
rm -rf "$LAYOUT"; mkdir -p "$LAYOUT/blobs/sha256"
python3 - "$WORK" "$LAYOUT" "$manifest_json" <<'EOF'
import json, os, hashlib, shutil, sys
W, L, MJ = sys.argv[1], sys.argv[2], sys.argv[3]
blobs = os.path.join(L, 'blobs', 'sha256')
m = json.load(open(MJ))

def place(digest):
    hexd = digest.split(':')[1]
    src = os.path.join(W, hexd)
    h = hashlib.sha256()
    with open(src, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 22), b''):
            h.update(chunk)
    assert h.hexdigest() == hexd, hexd
    shutil.copyfile(src, os.path.join(blobs, hexd))

place(m['config']['digest'])
for l in m['layers']:
    place(l['digest'])
mb = json.dumps(m).encode()
mhex = hashlib.sha256(mb).hexdigest()
open(os.path.join(blobs, mhex), 'wb').write(mb)
json.dump({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json",
           "manifests": [{"mediaType": m['mediaType'], "digest": "sha256:" + mhex,
                          "size": len(mb), "platform": {"architecture": "arm64", "os": "linux"}}]},
          open(os.path.join(L, 'index.json'), 'w'))
json.dump({"imageLayoutVersion": "1.0.0"}, open(os.path.join(L, 'oci-layout'), 'w'))
EOF
tar -C "$LAYOUT" -cf "$WORK/oci.tar" .
docker load -i "$WORK/oci.tar"
image_id=$(python3 -c "import json,sys;print('sha256:'+__import__('hashlib').sha256(json.dumps(json.load(open('$manifest_json'))).encode()).hexdigest())")
docker tag "$image_id" docker.1ms.run/gitlab/gitlab-ce:latest
docker tag "$image_id" gitlab/gitlab-ce:latest
log "完成：$(docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep gitlab/gitlab-ce | head -1)"
echo "现在可以重跑 ./gitlab_up.sh up"
