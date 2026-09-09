# =============================================================================
# versions.tf — Terraform 与 Provider 版本约束
#
# 为什么单独一个文件：
#   1. required_version 钉住 TF 核心行为（state 格式随大版本演进）；
#   2. required_providers 钉住 provider 小版本（~> 3.0 = 只锁大版本），
#      否则同事/CI 拉到不同版本 provider，plan 结果可能不一致。
#   3. `terraform init` 会据此生成 .terraform.lock.hcl —— 这是"依赖锁"，
#      提交进 git 才能保证团队所有人用一模一样的 provider 二进制。
# =============================================================================
terraform {
  required_version = ">= 1.6"

  required_providers {
    docker = {
      # kreuzwerker/docker 社区事实标准。钉 3.9.0 的原因（2026-09 本机实测）：
      #   - Docker 29 的 daemon 最低只接受 API 1.44，3.0.2 等老版本会报
      #     "client version 1.41 is too old"——新版 provider 才能对上新 daemon；
      #   - 老版本碰巧"能跑"通常是因为走了别的 daemon（OrbStack 容忍旧 API），
      #     换 daemon 就翻车——版本兼容要对着"真正在跑的 daemon"验证；
      #   - 实验脚本同时导出 DOCKER_HOST（见 scripts/docker-env.sh），
      #     避免 Go 客户端默认 socket 指向未运行的 daemon 而卡死。
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}

# 不显式配 host：provider 默认读 DOCKER_HOST / 本机默认 socket。
# macOS Docker Desktop 与 Linux 原生 docker 都开箱即用——"零配置连本机 daemon"。
provider "docker" {}
