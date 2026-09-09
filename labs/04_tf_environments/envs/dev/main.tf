# =============================================================================
# 方式二 · 目录法：envs/dev —— 每个环境一个独立根模块
#
# 教学点：
#   1. 环境隔离是物理的：不同目录 = 不同 state = 不同 apply 入口；
#   2. 参数直接写死在本目录（或 -var-file），一目了然，没有查表逻辑；
#   3. 代价：公共逻辑靠 module 复用，目录间的差异靠人眼 review。
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

  name       = "tf04-dir-dev"
  image      = "nginx:1.27-alpine"   # dev 参数：直接可见
  port_base  = 28093
  replicas   = 1
}

output "urls" {
  value = [for i in range(1) : "http://localhost:${28093 + i}/"]
}
