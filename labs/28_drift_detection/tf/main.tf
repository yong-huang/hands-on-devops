# =============================================================================
# 期望态（TF 管基础设施）：web 容器（名称/镜像 tag/端口归属 TF 管）
# 容器内配置（motd / web 根目录）归 ansible 管——分层治理
# =============================================================================
terraform {
  required_version = ">= 1.0"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}

provider "docker" {}

variable "app_port" {
  type    = number
  default = 28230
}

resource "docker_container" "web" {
  name    = "drift28-web"
  image   = "localhost:5500/drift28/app:1.0"
  must_run = true
  # OrbStack daemon 默认注入的 log 轮转配置——期望态必须显式对齐，
  # 否则 refresh 时 log_opts 永久 force-replacement diff（实测）
  log_opts = {
    "max-file" = "5"
    "max-size" = "20m"
  }
  ports {
    internal = 80
    external = var.app_port
  }
  command = ["python3", "-m", "http.server", "80", "--directory", "/srv"]
}
