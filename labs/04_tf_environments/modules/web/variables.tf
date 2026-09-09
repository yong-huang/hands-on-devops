# =============================================================================
# modules/web/variables.tf — 环境差异全部从这三个口子进来
# =============================================================================
variable "name" {
  description = "实例名前缀"
  type        = string
}

variable "image" {
  description = "镜像版本（环境的第一个差异点）"
  type        = string
}

variable "port_base" {
  description = "宿主机端口基数，副本依次 +1"
  type        = number
}

variable "replicas" {
  description = "副本数（环境的第二个差异点）"
  type        = number
  default     = 1
}
