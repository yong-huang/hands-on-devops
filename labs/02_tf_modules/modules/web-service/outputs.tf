# =============================================================================
# modules/web-service/outputs.tf — 模块的返回值
# =============================================================================

output "url" {
  description = "实例访问地址"
  value       = "http://localhost:${var.host_port}/"
}

output "container_name" {
  description = "容器名（观察环节 docker ps 用）"
  value       = docker_container.web.name
}
