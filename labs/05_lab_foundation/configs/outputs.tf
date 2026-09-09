# =============================================================================
# outputs.tf — 靶场回执：后续实验的"服务目录"
# =============================================================================

output "endpoints" {
  description = "靶场服务清单（make lab-status 可见）"
  value = {
    app      = "http://localhost:${var.app_port}/"
    registry = "http://localhost:${var.registry_port}/v2/_catalog"
    minio    = { s3 = "http://localhost:9000", console = "http://localhost:9001", user = "minioadmin" }
    gitea    = { web = "http://localhost:${var.gitea_port}/", admin = var.gitea_admin_user }
  }
}
