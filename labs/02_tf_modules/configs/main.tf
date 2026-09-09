# =============================================================================
# configs/main.tf — 根模块：for_each 一处定义、两处实例化
#
# 教学点：for_each 用 map 而不是 count，是为了"按键名增删"——
# 删 green 只销毁 green（count 用序号，删中间一个会引发后面的全部重建）。
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

# 镜像版本提为根变量：upgrade 演示用 -var 覆盖（不认识"undeclared variable"的坑见 README）
variable "image" {
  description = "web 服务镜像版本，两实例共用——升级即同步"
  type        = string
  default     = "nginx:1.27-alpine"
}

# 实例表：加一个键 = 多一套服务；改公共逻辑 = 所有实例同步更新
locals {
  instances = {
    blue = {
      host_port  = 28081
      index_html = "<h1>web-service · blue</h1>"
    }
    green = {
      host_port  = 28082
      index_html = "<h1>web-service · green</h1>"
    }
  }
}

module "web" {
  source   = "../modules/web-service"
  for_each = local.instances

  name       = "tf02-${each.key}"
  image      = var.image
  host_port  = each.value.host_port
  index_html = each.value.index_html
}
