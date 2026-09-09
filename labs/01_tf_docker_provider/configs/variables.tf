# =============================================================================
# variables.tf — 实验可调参数
#
# 教学点：变量是 TF 的"输入接口"。改端口/镜像不碰 resource 代码，
# 只需 -var 或 tfvars —— 这就是"配置与代码分离"在 IaC 里的样子。
# =============================================================================

variable "app_name" {
  description = "资源名前缀：所有资源共用，改名即换一套环境（TF 按 name 找旧资源）"
  type        = string
  default     = "tf01"
}

variable "image" {
  description = "nginx 镜像 tag。改成 1.25-alpine 再 plan，观察 'in-place update' vs 重建"
  type        = string
  default     = "nginx:1.27-alpine"
}

variable "host_port" {
  description = "宿主机映射端口；默认 28080（本系列专用段，避开 8080/18080 等常见占用）"
  type        = number
  default     = 28080
}

variable "index_html" {
  description = "写进数据卷的首页内容（模拟'应用代码'，与镜像内容分离）"
  type        = string
  default     = "<h1>hands-on-devops · lab01 · served by terraform</h1>"
}
