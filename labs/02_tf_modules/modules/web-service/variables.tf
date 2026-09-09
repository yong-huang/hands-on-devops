# =============================================================================
# modules/web-service/variables.tf — 模块的输入接口
#
# 教学点：module = 基础设施世界的"函数"。variables 是形参，root 传实参；
# outputs 是返回值。模块内部不写死任何环境差异（端口/名字/内容）。
# =============================================================================

variable "name" {
  description = "实例名前缀（blue/green），模块内所有资源都挂这个前缀"
  type        = string
}

variable "image" {
  description = "服务镜像；默认 nginx，模块使用者可换"
  type        = string
  default     = "nginx:1.27-alpine"
}

variable "host_port" {
  description = "宿主机端口，两个实例必须不同（端口是宿主机全局资源）"
  type        = number
}

variable "index_html" {
  description = "首页内容——升级实验里改它，观察两个实例同步更新"
  type        = string
  default     = "<h1>web-service · v1</h1>"
}
