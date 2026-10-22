# =============================================================================
# configs/main.tf — 被管资源刻意保持很少：本实验的主角是 state 不是资源
#
# 演示清单：
#   state mv    —— 资源改名（docker_volume.db → docker_volume.database），
#                  state 里改地址，实际卷纹丝不动；
#   state rm    —— "遗忘"资源：TF 不再管它，卷还活着（对比 destroy）；
#   import      —— 收编野生资源：手动 docker volume create 出来的卷，
#                  import 进 state 后开始被 TF 管理；
#   sensitive   —— 变量标记 sensitive 只是"输出打码"，state 里照样明文。
# =============================================================================

# 被 TF 管理的数据卷（state mv 的主角，改名演示后地址变为 docker_volume.database）
resource "docker_volume" "db" {
  name = "tf03-db"
}

# 挂着卷的一次性容器：证明 volume 与 container 是两个独立的 state 条目
resource "docker_container" "keeper" {
  name    = "tf03-keeper"
  image   = "alpine:3.20"
  command = ["sh", "-c", "echo state-deep-dive > /data/README && sleep 1"]

  volumes {
    volume_name    = docker_volume.db.name
    container_path = "/data"
  }

  must_run = false

  lifecycle {
    ignore_changes = [image]
  }
}

# 敏感值演示：sensitive 变量会进 state（明文），但输出会被打码
variable "api_token" {
  description = "演示用 token（sensitive）"
  type        = string
  sensitive   = true
  default     = "super-secret-token-do-not-commit"
}

output "token_masked" {
  description = "输出里 sensitive 会被打码，但……"
  value       = var.api_token
  sensitive   = true
}




















