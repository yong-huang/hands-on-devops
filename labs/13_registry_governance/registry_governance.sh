#!/usr/bin/env bash
# =============================================================================
# 13 · Registry 治理 — 主演示脚本
#
# ./registry_governance.sh auth     起带认证的 registry（5550）+ docker login + 推拉
# ./registry_governance.sh gc       删除废弃 manifest → GC → 磁盘占用前后对比
# ./registry_governance.sh retain   保留策略：每仓库只留最近 N 个 tag
# ./registry_governance.sh clean    销毁 registry 与数据卷
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

C="lab13-registry"
REG="localhost:5550"
USER="devops"
PASS="regpass123"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

disk_usage() { docker exec "$C" du -sk /var/lib/registry 2>/dev/null | awk '{printf "%.1fMB", $1/1024}'; }

start_registry() {
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker volume rm -f lab13-reg-data >/dev/null 2>&1 || true
    mkdir -p auth
    # -B bcrypt：registry htpasswd 只认 bcrypt；明文/MD5 会直接拒绝启动
    htpasswd -Bbn "$USER" "$PASS" > auth/htpasswd
    docker run -d --name "$C" -p 5550:5000 \
        -v "$(pwd)/config/config.yml:/etc/docker/registry/config.yml:ro" \
        -v "$(pwd)/auth/htpasswd:/auth/htpasswd:ro" \
        -v lab13-reg-data:/var/lib/registry \
        registry:2 >/dev/null
    local i=0
    until curl -sf -u "$USER:$PASS" "http://$REG/v2/" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 30 ] && { echo "    [!] registry 30s 未就绪" >&2; exit 1; }
        sleep 1
    done
}

gen_images() {
    # 三个 tag，各带一块 5MB 独立数据层（GC 效果可量化）
    mkdir -p ctx
    local i=1
    while [ $i -le 3 ]; do
        dd if=/dev/urandom of=ctx/data-$i.bin bs=1048576 count=5 2>/dev/null
        cat > ctx/Dockerfile <<EOF
FROM alpine:3.20
COPY data-$i.bin /data.bin
EOF
        docker build -q -t "$REG/demo/app:v$i" ctx >/dev/null
        i=$((i+1))
    done
    rm -rf ctx
}

do_auth() {
    step "auth" "带认证的 registry：匿名 401，登录后推拉"
    start_registry

    note "匿名访问（预期 401）"
    curl -s -o /dev/null -w '%{http_code}\n' "http://$REG/v2/_catalog" | sed 's/^/        /'

    note "docker login（凭据进 ~/.docker/config.json）"
    echo "$PASS" | docker login "$REG" -u "$USER" --password-stdin >/dev/null && note "[ok] 登录成功"

    note "生成 3 个各带 5MB 独立层的版本并推送"
    gen_images
    for v in 1 2 3; do docker push -q "$REG/demo/app:v$v" >/dev/null; done
    curl -s -u "$USER:$PASS" "http://$REG/v2/_catalog" | sed 's/^/        /'
    curl -s -u "$USER:$PASS" "http://$REG/v2/demo/app/tags/list" | sed 's/^/        /'

    note "拉取验证：docker pull $REG/demo/app:v1"
    docker pull -q "$REG/demo/app:v1" >/dev/null && note "[ok] 推拉链路通（认证生效）"
}

do_gc() {
    step "gc" "删除 v2 → GC → 磁盘占用前后对比"
    note "GC 前：$(disk_usage)"
    # 拿到 v2 的 digest（registry 的删除以 digest 为键）
    # 删除键是 manifest digest（响应头 Docker-Content-Digest），不是 config blob 的 digest
    local digest
    digest=$(curl -sI -u "$USER:$PASS" -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json" \
        "http://$REG/v2/demo/app/manifests/v2" | tr -d '\r' | grep -i Docker-Content-Digest | awk '{print $2}')
    # 先取子 manifest（OCI index 的 platforms 条目），再删索引——删完就查不到了
    local children
    children=$(curl -s -u "$USER:$PASS" -H "Accept: application/vnd.oci.image.index.v1+json" \
        "http://$REG/v2/demo/app/manifests/$digest" | jq -r '.manifests[].digest' 2>/dev/null)
    curl -s -u "$USER:$PASS" -X DELETE "http://$REG/v2/demo/app/manifests/$digest" -o /dev/null -w '        DELETE tag(index) → %{http_code}\n'
    for child in $children; do
        curl -s -u "$USER:$PASS" -X DELETE "http://$REG/v2/demo/app/manifests/$child" -o /dev/null -w '        DELETE child manifest → %{http_code}\n'
    done
    note "（API 删除后 blob 仍占盘——GC 才真正回收）"
    docker stop "$C" >/dev/null
    docker run --rm -v lab13-reg-data:/var/lib/registry -v "$(pwd)/config/config.yml:/etc/docker/registry/config.yml:ro" \
        registry:2 registry garbage-collect /etc/docker/registry/config.yml 2>&1 | tail -3 | LC_ALL=C sed 's/^/        /'
    docker start "$C" >/dev/null && sleep 2
    note "GC 后：$(disk_usage)"
    note "[ok] 5MB 级别的占用差异已可量化；生产上 GC 放维护窗口并先停写"
}

do_retain() {
    step "retain" "保留策略脚本：demo/app 只保留最近 2 个 tag"
    local tags keep
    tags=$(curl -s -u "$USER:$PASS" "http://$REG/v2/demo/app/tags/list" | jq -r '.tags[]' | sort -V)
    keep=$(echo "$tags" | tail -2)
    note "现存: $(echo $tags | tr '\n' ' ')"
    note "保留: $(echo $keep | tr '\n' ' ')"
    for t in $tags; do
        echo "$keep" | grep -qx "$t" && continue
        local digest
        digest=$(curl -sI -u "$USER:$PASS" -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json" \
            "http://$REG/v2/demo/app/manifests/$t" | tr -d '\r' | grep -i Docker-Content-Digest | awk '{print $2}')
        curl -s -u "$USER:$PASS" -X DELETE "http://$REG/v2/demo/app/manifests/$digest" -o /dev/null
        note "删除超期 tag: $t"
    done
    note "[ok] 保留策略即代码：keep=N、排除 prod/*、按语义化版本排序都可脚本化"
}

do_clean() {
    step "clean" "销毁 registry + 数据卷 + 本机登录凭据"
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker volume rm -f lab13-reg-data >/dev/null 2>&1 || true
    docker logout "$REG" >/dev/null 2>&1 || true
    ! docker ps -a --format '{{.Names}}' | grep -q "^$C$" && note "[ok] 零残留" || { note "[!] 残留" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        auth)   do_auth ;;
        gc)     do_gc ;;
        retain) do_retain ;;
        clean)  do_clean ;;
        all)    do_auth; do_gc; do_retain; do_clean ;;
        *) echo "可用: auth | gc | retain | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
