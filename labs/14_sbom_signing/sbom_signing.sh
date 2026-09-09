#!/usr/bin/env bash
# =============================================================================
# 14 · SBOM + cosign 签名 — 主演示脚本
#
# 前置：靶场 registry :5500 在跑（实验 05）
# ./sbom_signing.sh sbom     syft 生成 SBOM（SPDX JSON + 人类可读表）
# ./sbom_signing.sh sign     生成密钥对 → 签名 → 验签（CI 可直接用的命令）
# ./sbom_signing.sh tamper   同 tag 覆盖攻击 → 验签失败（供应链攻防演示）
# ./sbom_signing.sh clean    清理签名密钥
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

REG="localhost:5500"
IMG="$REG/demo/signed:1.0.0"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

push_demo_image() {
    mkdir -p ctx
    cat > ctx/Dockerfile <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache curl
CMD ["crond", "-f"]
EOF
    docker build -q -t "$IMG" ctx >/dev/null
    rm -rf ctx
    docker push -q "$IMG" >/dev/null
}

do_sbom() {
    step "sbom" "syft 生成 SBOM：镜像里到底有什么"
    command -v syft >/dev/null || { echo "    [x] 缺 syft：brew install syft" >&2; exit 1; }
    push_demo_image
    mkdir -p artifacts
    syft "$IMG" -o spdx-json > artifacts/sbom.spdx.json
    syft "$IMG" -o table | head -14 | LC_ALL=C sed 's/^/        /'
    local n
    n=$(jq -r '.packages | length' artifacts/sbom.spdx.json)
    note "[ok] SBOM 已生成：artifacts/sbom.spdx.json（$n 个包）—— 软件供应链的'配料表'"
}

do_sign() {
    step "sign" "cosign 密钥对 + 签名 + 验签"
    command -v cosign >/dev/null || { echo "    [x] 缺 cosign：brew install cosign" >&2; exit 1; }
    mkdir -p tmp
    if [ ! -f tmp/cosign.key ]; then
        COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix tmp/cosign >/dev/null 2>&1
        note "[ok] 密钥对已生成（tmp/cosign.key 私钥绝不入库，见 .gitignore）"
    fi
    COSIGN_PASSWORD="" cosign sign --key tmp/cosign.key --yes "$IMG" 2>&1 | tail -2 | LC_ALL=C sed 's/^/        /'

    note "验签（CI 可直接复制的一条命令）"
    COSIGN_PASSWORD="" cosign verify --key tmp/cosign.pub "$IMG" 2>/dev/null \
        | jq -r '.[0].optional.DockerReference // "verified"' | sed 's/^/        [ok] /'

    note "签名去哪了？——registry 里多了一个 sha256-*.sig tag（与镜像同仓库存放）"
    curl -s "http://$REG/v2/demo/signed/tags/list" | sed 's/^/        /'
}

do_tamper() {
    step "tamper" "供应链攻击演示：同 tag 覆盖恶意镜像 → 验签失败"
    mkdir -p ctx
    cat > ctx/Dockerfile <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache curl && echo "malicious" > /etc/malware
CMD ["crond", "-f"]
EOF
    docker build -q -t "$IMG" ctx >/dev/null
    rm -rf ctx
    docker push -q "$IMG" >/dev/null
    note "tag 未变（攻击者覆盖了 1.0.0），digest 已变"
    local rc=0
    COSIGN_PASSWORD="" cosign verify --key tmp/cosign.pub "$IMG" >/dev/null 2>&1 || rc=$?
    if [ $rc -ne 0 ]; then
        note "[检出] cosign verify 失败（exit=${rc}）- 签名与 digest 绑定，篡改必被识破"
    else
        note "[x] 篡改未被识破？" >&2
    fi
    note "[结论] CI 部署前执行 verify：非授信 digest 一律拦截（实验 25 接入三道门）"
}

do_clean() {
    step "clean" "清理签名密钥与本地演示镜像"
    rm -rf tmp artifacts
    docker rmi -f "$IMG" >/dev/null 2>&1 || true
    note "[ok] 私钥已销毁（生产中私钥进 KMS/HSM，永不落地 CI 之外）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        sbom)   do_sbom ;;
        sign)   do_sign ;;
        tamper) do_tamper ;;
        clean)  do_clean ;;
        all)    do_sbom; do_sign; do_tamper; do_clean ;;
        *) echo "可用: sbom | sign | tamper | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
