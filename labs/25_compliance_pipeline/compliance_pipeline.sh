#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

step "gate1" "策略门（conftest）：OPA 规则检查"
conftest test ../22_opa_conftest/fixtures/bad-deployment.json -p ../22_opa_conftest/policies/ 2>&1 | tail -2 | sed 's/^/        /' || true
note "[策略门] 完成"

step "gate2" "安全门（trivy）：CRITICAL 阻断"
trivy config ../23_iac_scanning/bad-configs/ --severity CRITICAL 2>&1 | tail -3 | sed 's/^/        /' || true
note "[安全门] 完成"

step "gate3" "密钥门（gitleaks/grep）：明文扫描"
if grep -rq "password.*=" ../23_iac_scanning/bad-configs/ 2>/dev/null; then
    note "[检出] 明文密码存在于 IaC 配置中"
else
    note "[ok] 无明文密码"
fi
note "[密钥门] 完成"

note "[ok] 三道合规门验证完成"
