# =============================================================================
# main.tf — 被"锁"保护的最小资源组：1 镜像 + 1 个"故意很慢"的 sleep
#
# 为什么资源组里没有容器？
#   第一版用了 docker_container，本机 OrbStack 引擎会往新容器注入 daemon 级
#   日志轮转默认值（state 里出现 log_opts = {"max-file"=5, "max-size"=20m}），
#   而 plan 期计划值是 null → ForceNew 永久替换循环（apply 再多次也不收敛）。
#   本实验的主角是锁不是容器，所以换成零噪音的 docker_image + time_sleep。
#   坑的完整复盘在 README「Pitfalls & Q&A」；生产对照做法见坑内说明。
#
# 为什么需要一个 time_sleep（等一会儿）资源？
#   apply 的锁从开始拿到结束才释放。真实基础设施 apply 要几分钟，演示里
#   没那个耐心——time_sleep 的 create_duration 就是人为拉长的持锁窗口，
#   让第二个终端在窗口内撞锁。生产里同样的角色由"慢资源"扮演（数据库
#   迁移、实例启动），锁竞争天天发生，不是稀罕事。
# =============================================================================

# 持锁窗口长度：演示脚本会传 -var hold_seconds=45s 拉长窗口；
# 平时 apply 用默认 2s（几乎无感）
variable "hold_seconds" {
  type    = string
  default = "2s"

  validation {
    condition     = can(regex("^[0-9]+(s|m|h)$", var.hold_seconds))
    error_message = "hold_seconds 必须是带单位的时长，如 45s / 5m。"
  }
}

# 基础镜像：alpine:3 本机已有（零拉取）；docker_image 资源在 plan 里零 churn，
# 是本实验"被锁保护资源"的理想扮演者
resource "docker_image" "demo" {
  name = "alpine:3"
}

# 持锁窗口道具：镜像就绪后睡 hold_seconds 再结束 apply
resource "time_sleep" "hold_lock" {
  create_duration = var.hold_seconds

  depends_on = [docker_image.demo]
}

# 观察 state 在数据库里的落地（verify 阶段断言用）
output "demo_image" {
  value = docker_image.demo.name
}
