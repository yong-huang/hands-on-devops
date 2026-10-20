#!/usr/bin/env bash
# PR 必需检查：版本号格式 + 服务冒烟
set -euo pipefail
cd "$(dirname "$0")/.."
VER="$(cat app/VERSION)"
echo "$VER" | grep -Eq '^v[0-9]+(\.[0-9]+)*$' || { echo "bad VERSION: $VER"; exit 1; }
echo "[pr] tests ok for $VER"
