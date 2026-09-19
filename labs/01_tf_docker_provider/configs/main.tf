# =============================================================================
# main.tf — 网络 + 卷 + 一次性播种容器 + nginx 应用容器
#
# 本文件刻意演示四件事：
#   1. resource 之间的依赖图：TF 自动按引用推导创建顺序（network → volume →
#      seeder → app），destroy 反向拆除；
#   2. 显式 depends_on：seeder 与 app 之间没有直接引用（都只是"用卷"），
#      必须显式声明"app 等 seeder 写完"，否则 nginx 可能先起、页面 404；
#   3. 幂等：apply 两次，第二次 plan 为空（No changes）；
#   4. 漂移：手动 docker stop 后，plan 会检出实际状态偏离期望状态。
# =============================================================================

# --- 自定义桥接网络：容器间用容器名互访，不依赖宿主机端口 ---
resource "docker_network" "lab" {
  name = "${var.app_name}-net"

  # IPAM 网段显式声明：教学点——地址可预测，排查 tcpdump/抓包不抓瞎。
  # 坑：gateway 不写的话，daemon 回读会报出实际网关，与"未设置"形成
  # 永久假漂移（ipam 变更 = 整个网络重建）。写全 subnet+gateway 才稳定
  ipam_config {
    subnet  = "172.31.100.0/24"
    gateway = "172.31.100.1"
  }
}

# --- 数据卷：首页内容放卷里而不是镜像里（12-Factor：代码与数据分离）---
resource "docker_volume" "web_content" {
  name = "${var.app_name}-content"
}

# --- 一次性播种容器：跑完即退（alpine echo 进卷），模拟"部署时写入产物" ---
# 注意 replace 触发条件：内容变了才重跑——所以把内容做成容器名的一部分，
# name 变 = 销毁重建，这是 TF 表达"内容变更触发重建"的惯用小技巧。
resource "docker_container" "seed" {
  name    = "${var.app_name}-seed-${md5(var.index_html)}"
  image   = "alpine:3.20"
  command = ["sh", "-c", "echo '${var.index_html}' > /data/index.html"]

  volumes {
    volume_name    = docker_volume.web_content.name
    container_path = "/data"
  }

  # 跑完自动退出；不会常驻
  must_run = false

  # 防止每次 plan 都因镜像更新检测产生 diff（假漂移）；log_opts 是 OrbStack
  # 内置的日志轮转默认值，provider 会记进 state，不忽略则每次 plan 都 forces
  # replacement（另一种假漂移，Docker Desktop 无此默认值故平时不可见）
  lifecycle {
    ignore_changes = [image, log_opts]
  }
}

# --- 镜像声明为资源：TF 负责 pull，容器引用它的 image_id ---
# 为什么不直接写 image = "nginx:1.27-alpine"？
#   直接写 tag 的话，provider 刷新时把容器 .Image 报成 sha256 摘要，
#   与配置里的 tag 永远对不上 → 每次 plan 都显示 forces replacement（假漂移）。
#   让容器引用 docker_image.app_image.image_id，两边都是摘要，plan 才稳定；
#   改 var.image 时 image 资源先变、容器跟着重建——升级路径依然成立。
resource "docker_image" "app_image" {
  name         = var.image
  keep_locally = true # destroy 容器后镜像留在本机，反复实验不重复拉取
}

# --- 应用容器：nginx 挂卷只读，暴露宿主机端口 ---
resource "docker_container" "app" {
  name  = "${var.app_name}-nginx"
  image = docker_image.app_image.image_id

  # 只读挂载：容器即使被入侵也改不掉首页——最小权限思想的最小示例
  volumes {
    volume_name    = docker_volume.web_content.name
    container_path = "/usr/share/nginx/html"
    read_only      = true
  }

  networks_advanced {
    name = docker_network.lab.name
  }

  ports {
    internal = 80
    external = var.host_port
  }

  # 健康检查：TF 不轮询它，但 docker ps 会显示 (healthy)，观察环节用到
  healthcheck {
    test     = ["CMD", "wget", "-qO-", "http://localhost/"]
    interval = "5s"
    timeout  = "3s"
    retries  = 3
  }

  restart = "no" # 漂移实验要手动 stop；若配 always 会被 daemon 拉起来，演示失败

  # OrbStack 内置日志轮转默认值会被 provider 记进 state（同 seed 的说明），
  # 不忽略则每次 plan 都 forces replacement
  lifecycle {
    ignore_changes = [log_opts]
  }

  # 关键：seeder 与 app 无字段引用，必须显式依赖保证"先播种、后开服"
  depends_on = [docker_container.seed]
}
