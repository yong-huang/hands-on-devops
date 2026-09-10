#!/usr/bin/env bash
set -euo pipefail
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
step "all-in-one" "DevOps 一体机（前置 01-29 全部完成）"
note "make lab-up         → 靶场就绪（实验 05）"
note "cd labs/06 && ./ansible_role_vault.sh  → 配置管理"
note "cd labs/11 && ./image_slimming.sh      → 镜像优化"
note "cd labs/16 && ./jenkins_basics.sh      → CI 流水线"
note "cd labs/18 && ./gitea_actions.sh       → GitOps 触发"
note "cd labs/21 && ./flux_gitops.sh         → Flux GitOps"
note "cd labs/22 && ./woodpecker_test.sh     → 策略门禁"
note "cd labs/23 && ./iac_scanning.sh        → 安全扫描"
note "cd labs/24 && ./sops_age.sh            → 密钥治理"
echo "[ok] DevOps 一体机全链路演示完毕"
