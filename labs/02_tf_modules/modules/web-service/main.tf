# =============================================================================
# modules/web-service/main.tf — 一个自包含的"web 服务"积木
#
# 镜像 + 卷 + 容器三件套。实验 1 里这四个资源散在根模块；现在封装成模块，
# 一处修改、处处生效（本实验两处实例化：blue/green）。
# =============================================================================

terraform {
  # 模块内部也要声明 provider 约束（与 root 一致）；provider 本体由 root 安装
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}

# 镜像声明为资源：坑①（image 直接写 tag 会有假漂移）在模块里同样成立
resource "docker_image" "this" {
  name         = var.image
  keep_locally = true
}

# 数据卷：每个实例一份内容，互不干扰
resource "docker_volume" "content" {
  name = "${var.name}-content"
}

# 播种容器：把首页写进卷（与实验 1 相同的"内容变更即重建"技巧）
resource "docker_container" "seed" {
  name    = "${var.name}-seed-${md5(var.index_html)}"
  image   = "alpine:3.20"
  command = ["sh", "-c", "echo '${var.index_html}' > /data/index.html"]

  volumes {
    volume_name    = docker_volume.content.name
    container_path = "/data"
  }

  must_run = false

  lifecycle {
    ignore_changes = [image]
  }
}

# 应用容器：带健康检查，wait=true 让 apply 等到 healthy 才返回
resource "docker_container" "web" {
  name  = "${var.name}-web"
  image = docker_image.this.image_id

  volumes {
    volume_name    = docker_volume.content.name
    container_path = "/usr/share/nginx/html"
    read_only      = true
  }

  ports {
    internal = 80
    external = var.host_port
  }

  healthcheck {
    test     = ["CMD", "wget", "-qO-", "http://localhost/"]
    interval = "5s"
    timeout  = "3s"
    retries  = 3
  }

  restart = "no"

  depends_on = [docker_container.seed]
}
