# =============================================================================
# configs/outputs.tf — 把每个实例的返回值聚合输出
#
# 教学点：for_each 的资源/模块输出是 map，取值要按键：
#   module.web["blue"].url
# =============================================================================

output "instances" {
  description = "两套实例的访问地址与容器名"
  value = {
    for k, inst in module.web : k => { url = inst.url, container = inst.container_name }
  }
}
