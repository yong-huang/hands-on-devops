#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
step "drift" "Terraform plan 检测基础设施漂移"
note "原理：TF plan 对比声明状态 vs 实际状态；drift → exit 2"
note "检测命令: terraform plan -detailed-exitcode"
note "  exit 0 = 无漂移; exit 2 = 有漂移; exit 1 = 出错"
note "治理: drift → 分析根因 → git push 修复 → TF apply 回正"
