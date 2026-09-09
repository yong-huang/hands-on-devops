# =============================================================================
# nginx.pkr.hcl — Packer HCL2：用"IaC 思想"造镜像
#
# 管道：docker builder（起临时容器）→ ansible provisioner（复用实验 06 的 role）
#      → docker-tag/docker-push（推靶场私有 registry :5500）
# 镜像即代码：本文件与 .tf 一样可 review、可 diff、可重复构建。
# =============================================================================
packer {
  required_version = ">= 1.9"

  required_plugins {
    docker = {
      source  = "github.com/hashicorp/docker"
      version = ">= 1.0.0"
    }

    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = ">= 1.0.0"
    }
  }
}

variable "app_version" {
  type    = string
  default = "1.0.0"
}

variable "registry" {
  type    = string
  default = "localhost:5500"
}

source "docker" "nginx" {
  image  = "python:3.12-slim"   # 带 python3 → ansible 模块可用；apt 装 nginx
  commit = true                 # 提交容器为镜像（而非导出 tar）
  changes = [
    "EXPOSE 8080",
    "CMD [\"nginx\", \"-g\", \"daemon off;\"]",
  ]
}

build {
  sources = ["source.docker.nginx"]

  # Ansible provisioner：docker 连接插件直连构建容器（use_proxy=false）
  provisioner "ansible" {
    playbook_file       = "ansible/nginx.yml"
    use_proxy          = false
    user               = "root"
    extra_arguments = [
      "--extra-vars", "app_name=packer-nginx app_env=lab",
    ]
  }

  # 嵌套 post-processors 块 = 顺序执行链：tag 的产物交给 push
  # （两个平级 post-processor 会各自拿到"未打 tag"的原始 sha，push 直奔 docker.io）
  post-processors {
    post-processor "docker-tag" {
      repository = "${var.registry}/packer-nginx"
      tags       = [var.app_version, "latest"]
    }

    post-processor "docker-push" {}
  }
}
