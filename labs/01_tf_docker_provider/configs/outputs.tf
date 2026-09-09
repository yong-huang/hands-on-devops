# =============================================================================
# outputs.tf — apply 之后的"回执"
#
# 教学点：output 是模块/环境对外暴露的接口。实验 05 的靶场会把
# registry/gitea/minio 的地址全部 output 出去，供后续实验与 CI 消费。
# =============================================================================

output "app_url" {
  description = "本地访问地址"
  value       = "http://localhost:${var.host_port}/"
}

output "container_id" {
  description = "容器 ID 前 12 位（docker inspect 用）"
  value       = substr(docker_container.app.id, 0, 12)
}

output "managed_resources" {
  description = "本实验管理的全部资源（与 terraform state list 对照）"
  value = [
    docker_network.lab.name,
    docker_volume.web_content.name,
    docker_container.seed.name,
    docker_container.app.name,
  ]
}
