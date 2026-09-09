# =============================================================================
# 方式二 · 目录法：envs/staging —— 与 dev 同构，参数不同
#
# staging 的差异一眼可见：镜像新一个小版本（1.29）、副本翻倍、端口段后移。
# =============================================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}

provider "docker" {}

module "web" {
  source = "../../modules/web"

  name       = "tf04-dir-staging"
  image      = "nginx:1.29-alpine"  # staging 参数：更激进的版本
  port_base  = 28094
  replicas   = 2                    # 副本翻倍
}

output "urls" {
  value = [for i in range(2) : "http://localhost:${28094 + i}/"]
}
