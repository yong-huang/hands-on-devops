#!/usr/bin/env bash
# =============================================================================
# 15 · 集成点② 手工发布流水线 — 串起实验 11-14 的全部能力
#
# ./release_pipeline.sh release VERSION=1.2.3
#   构建(distroless 多阶段) → SBOM → 签名 → 推仓 → 验签门 → 部署靶场 → 冒烟 → 追溯清单
# ./release_pipeline.sh clean   销毁部署容器
# 产物全链路可追溯：镜像 digest / SBOM 校验和 / 签名 tag / 部署时间 一张表。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

REG="${REG:-localhost:5500}"
VERSION="${VERSION:-dev}"
IMAGE="$REG/demo/webapp:$VERSION"
NET="devops-lab"
PORT=28099

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

prepare_keys() {
    mkdir -p tmp
    if [ ! -f tmp/cosign.key ]; then
        COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix tmp/cosign >/dev/null 2>&1
        note "[ok] 发布密钥对已生成（tmp/，gitignore）"
    fi
}

do_release() {
    [ "$VERSION" = "dev" ] && { echo "[x] 请指定版本：make release VERSION=1.2.3" >&2; exit 1; }
    prepare_keys

    step "1/6 build" "distroless 多阶段构建 $IMAGE"
    docker build -q -f Dockerfile -t "$IMAGE" . >/dev/null

    step "2/6 sbom" "syft 生成软件物料清单"
    mkdir -p artifacts
    syft "$IMAGE" -o spdx-json > "artifacts/sbom-$VERSION.json"
    local pkgs
    pkgs=$(jq -r '.packages | length' "artifacts/sbom-$VERSION.json")
    note "SBOM：artifacts/sbom-$VERSION.json（$pkgs 个包）"

    step "3/6 push" "推送镜像到 ${REG} （签名附着在 registry，必须先有镜像）"
    docker push -q "$IMAGE" >/dev/null

    step "4/6 sign" "cosign 签名（绑定 digest，签名 tag 同仓入库）"
    COSIGN_PASSWORD="" cosign sign --key tmp/cosign.key --yes "$IMAGE" >/dev/null 2>&1
    note "[ok] 签名完成"
    local digest
    digest=$(docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null | awk -F@ '{print $2}') || true
    if [ -z "$digest" ]; then
        digest=$(docker exec lab-registry sh -c "ls /var/lib/registry/docker/registry/v2/repositories/demo/webapp/_manifests/revisions/sha256/" 2>/dev/null | tail -1)
    fi
    note "镜像 digest：$digest"

    step "5/6 gate" "部署前验签门（非零即阻断）"
    COSIGN_PASSWORD="" cosign verify --key tmp/cosign.pub "$IMAGE" >/dev/null 2>&1 \
        && note "[ok] 验签通过" || { note "[x] 验签失败，阻断发布" >&2; exit 1; }

    step "6/6 deploy" "部署到靶场网络 + 冒烟"
    docker rm -f demo-webapp >/dev/null 2>&1 || true
    docker run -d --name demo-webapp --network "$NET" -p "$PORT:8080" "$IMAGE" >/dev/null
    local i=0
    until curl -fsS "http://localhost:$PORT/healthz" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 20 ] && { echo "    [!] 应用 20s 未就绪" >&2; exit 1; }
        sleep 1
    done
    note "curl :$PORT/healthz → $(curl -s "http://localhost:$PORT/healthz")"

    step "trace" "发布追溯清单（写盘 artifacts/release-$VERSION.txt）"
    local sbomsum ts
    sbomsum=$(shasum -a 256 "artifacts/sbom-$VERSION.json" | awk '{print $1}')
    ts=$(date '+%F %T')
    cat > "artifacts/release-$VERSION.txt" <<EOF
版本:        $VERSION
镜像:        $IMAGE
镜像 digest: $digest
SBOM 校验和: $sbomsum
签名 tag:    sha256-${digest#sha256:}.sig
部署位置:    demo-webapp@$NET :$PORT
冒烟结果:    healthz 200 @ $ts
EOF
    cat "artifacts/release-$VERSION.txt" | sed 's/^/        /'
    note "[ok] 发布完成，产物全链路可追溯"
}

do_clean() {
    step "clean" "销毁部署容器"
    docker rm -f demo-webapp >/dev/null 2>&1 || true
    ! docker ps -a --format '{{.Names}}' | grep -q '^demo-webapp$' && note "[ok] 零残留" || { note "[!] 残留" >&2; exit 1; }
}

main() {
    local target="${1:-release}"
    case "${target}" in
        release) shift || true; eval set -- "$@"; for a in "$@"; do case $a in VERSION=*) VERSION=${a#VERSION=};; REG=*) REG=${a#REG=};; esac; done; IMAGE="$REG/demo/webapp:$VERSION"; do_release ;;
        clean)   do_clean ;;
        *) echo "可用: release VERSION=x | clean" >&2; exit 1 ;;
    esac
}

main "$@"
