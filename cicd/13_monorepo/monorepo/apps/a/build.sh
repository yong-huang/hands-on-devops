#!/usr/bin/env bash
# 模块 a 的构建：产出 marker 到 artifacts/（真实项目里是编译/打包）
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p artifacts
dep="$(bash libs/common/common.sh)"
echo "a built at $(date -u +%FT%TZ) commit $(git rev-parse --short HEAD) lib=$dep" > artifacts/a.txt
echo "[a] build ok"
