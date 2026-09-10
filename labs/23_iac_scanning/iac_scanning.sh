#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

step "scan" "tfsec 扫描坏配置"
tfsec bad-configs/ 2>&1 | tail -5 | sed 's/^/        /' || true

step "scan" "trivy config 扫描"
trivy config bad-configs/ 2>&1 | tail -8 | sed 's/^/        /' || true

step "scan" "对比：好配置"
tfsec good-configs/ 2>&1 | tail -3 | sed 's/^/        /' || true
note "[ok] 扫描完成——tfsec/trivy 的 Rules 表就是安全基线"
