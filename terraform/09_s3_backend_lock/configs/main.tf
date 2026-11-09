# =============================================================================
# main.tf — 被锁保护的最小资源组：1 镜像 + 1 个"故意很慢"的 sleep
#
# 与项目 08 同款资源组（docker_image + time_sleep，零替换噪音）：
#   - time_sleep 的 create_duration 是人为拉长的持锁窗口，让并发 apply
#     在窗口内撞锁；生产里这个角色由慢资源扮演（数据库迁移、实例启动）
#   - 不用 docker_container 的原因见项目 08 README 的 OrbStack log_opts 坑
# =============================================================================

variable "hold_seconds" {
  type    = string
  default = "2s"

  validation {
    condition     = can(regex("^[0-9]+(s|m|h)$", var.hold_seconds))
    error_message = "hold_seconds 必须是带单位的时长，如 45s / 5m。"
  }
}

resource "docker_image" "demo" {
  name = "alpine:3"
}

resource "time_sleep" "hold_lock" {
  create_duration = var.hold_seconds

  depends_on = [docker_image.demo]
}

output "demo_image" {
  value = docker_image.demo.name
}
