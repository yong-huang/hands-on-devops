# =============================================================================
# modules/web/main.tf — 可参数化的 web 服务（实验 04 两法共用）
#
# 与实验 02 的模块同思路，这里多了两个环境参数：
#   replicas —— 副本数（count 展开，端口依次 +1 偏移）
#   image    —— 镜像版本（dev 跑 1.27、staging 跑 1.29：环境差异的第一现场）
# =============================================================================

terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}

resource "docker_image" "app" {
  name         = var.image
  keep_locally = true
}

# count = 副本数：无状态服务用 count 合适（实验 02 讲过 for_each vs count 的取舍）
resource "docker_container" "app" {
  count = var.replicas

  name  = "${var.name}-${count.index + 1}"
  image = docker_image.app.image_id

  ports {
    internal = 80
    # 端口偏移：副本 0→base，副本 1→base+1……宿主机端口全局唯一
    external = var.port_base + count.index
  }

  healthcheck {
    test     = ["CMD", "wget", "-qO-", "http://localhost/"]
    interval = "5s"
    timeout  = "3s"
    retries  = 3
  }

  restart = "no"

  lifecycle {
    ignore_changes = [log_opts, network_mode]
  }
}
