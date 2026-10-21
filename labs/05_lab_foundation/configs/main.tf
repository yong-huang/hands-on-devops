# =============================================================================
# main.tf — devops-lab 网络 + 四件套容器
#
# 设计原则：
#   1. 全部容器挂同一自定义网络 devops-lab，容器名即 DNS（gitea 能直呼 minio）；
#   2. 数据全部进命名卷，destroy 不留残骸，重新 apply 数据为空（实验 29 演练备份）；
#   3. registry 开删除接口（实验 13 的 GC 需要）。
# =============================================================================

resource "docker_network" "lab" {
  name = "devops-lab"
}

# ---- 目标应用：本系列"被部署的业务" ----
resource "docker_container" "app" {
  name  = "lab-nginx"
  image = "nginx:1.27-alpine"

  networks_advanced { name = docker_network.lab.name }

  ports {
    internal = 80
    external = var.app_port
  }

  healthcheck {
    test     = ["CMD", "wget", "-qO-", "http://localhost/"]
    interval = "5s"
    timeout  = "3s"
    retries  = 3
  }

  restart = "no"
  lifecycle { ignore_changes = [log_opts, network_mode] }
}

# ---- 私有镜像仓：实验 12-15 往这里推镜像 ----
resource "docker_container" "registry" {
  name  = "lab-registry"
  image = "registry:2"

  networks_advanced { name = docker_network.lab.name }

  ports {
    internal = 5000
    external = var.registry_port
  }

  # 开删除 API：GC/保留策略（实验 13）必需
  env = ["REGISTRY_STORAGE_DELETE_ENABLED=true"]

  volumes {
    volume_name    = docker_volume.registry_data.name
    container_path = "/var/lib/registry"
  }

  healthcheck {
    test     = ["CMD", "wget", "-qO-", "http://localhost:5000/v2/"]
    interval = "5s"
    timeout  = "3s"
    retries  = 3
  }

  restart = "no"
  lifecycle { ignore_changes = [log_opts, network_mode] }
}

resource "docker_volume" "registry_data" {
  name = "lab-registry-data"
}

# ---- S3 兼容存储：state 后端 / 备份目标 ----
resource "docker_container" "minio" {
  name  = "lab-minio"
  image = "minio/minio:latest"

  networks_advanced { name = docker_network.lab.name }

  command = ["server", "/data", "--console-address", ":9001"]

  ports {
    internal = 9000
    external = 9100  # 宿主 91xx：与 hands-on-mlops 的 90xx MinIO 错开
  }
  ports {
    internal = 9001
    external = 9101
  }

  env = ["MINIO_ROOT_USER=minioadmin", "MINIO_ROOT_PASSWORD=minioadmin"]

  volumes {
    volume_name    = docker_volume.minio_data.name
    container_path = "/data"
  }

  healthcheck {
    test     = ["CMD", "mc", "ready", "local"]
    interval = "10s"
    timeout  = "5s"
    retries  = 3
  }

  restart = "no"
  lifecycle { ignore_changes = [log_opts, network_mode] }
}

resource "docker_volume" "minio_data" {
  name = "lab-minio-data"
}

# ---- Git 服务：CI/GitOps 的代码源 ----
resource "docker_container" "gitea" {
  name  = "lab-gitea"
  image = "gitea/gitea:1.22"

  networks_advanced { name = docker_network.lab.name }

  ports {
    internal = 3000
    external = var.gitea_port
  }

  env = [
    # 跳过首次安装向导，后续实验直接建仓库
    "GITEA__security__INSTALL_LOCK=true",
    "GITEA__server__ROOT_URL=http://localhost:${var.gitea_port}/",
    "USER_UID=1000",
    "USER_GID=1000",
  ]

  volumes {
    volume_name    = docker_volume.gitea_data.name
    container_path = "/data"
  }

  restart = "no"
  lifecycle { ignore_changes = [log_opts, network_mode] }
}

resource "docker_volume" "gitea_data" {
  name = "lab-gitea-data"
}
