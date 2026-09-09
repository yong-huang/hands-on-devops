# =============================================================================
# 方式一 · workspace 法：一份配置 + 多个 workspace
#
# 教学点：
#   1. `terraform.workspace` 是唯一的环境变量——配置里用它查参数表；
#   2. 每个 workspace 一份独立 state（dev/staging 互不干扰）；
#   3. 条件表达式（?:）演示"不在表里怎么办"：回退到默认值。
#
# 隐忧（README 对比表详述）：环境差异藏在代码里的 map，漏一个 key 就是
# 运行时错误；所有环境共用一份配置，改坏一处全体遭殃。
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

# 环境参数表：workspace 名 → 参数。差异是"数据"，不是"代码"
locals {
  envs = {
    dev     = { image = "nginx:1.27-alpine", port_base = 28090, replicas = 1 }
    staging = { image = "nginx:1.29-alpine", port_base = 28091, replicas = 2 }
  }

  # 条件表达式：当前 workspace 在表里就用表值，不在就回退 dev 参数（防止拼写错误直接炸）
  env     = lookup(local.envs, terraform.workspace, local.envs.dev)
  is_stag = terraform.workspace == "staging" ? true : false
}

module "web" {
  source = "../modules/web"

  name       = "tf04-ws-${terraform.workspace}"
  image      = local.env.image
  port_base  = local.env.port_base
  replicas   = local.env.replicas
}

output "workspace"   { value = terraform.workspace }
output "is_staging"  { value = local.is_stag }
output "urls" {
  value = [for i in range(local.env.replicas) : "http://localhost:${local.env.port_base + i}/"]
}
