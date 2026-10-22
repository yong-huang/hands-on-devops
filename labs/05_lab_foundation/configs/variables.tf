# =============================================================================
# variables.tf — 靶场可调参数
# =============================================================================
variable "app_port" {
  description = "靶场 nginx 应用端口（28085：长驻靶场专用。全系列端口表见根 README——28080=实验01，28081/28082=实验02，28090-28095=实验04，2810x/2811x=实验08-15）"
  type        = number
  default     = 28085
}

variable "registry_port" {
  description = "私有 registry 端口（5500，避开 macOS AirPlay 占用的 5000）"
  type        = number
  default     = 5500
}

variable "gitea_port" {
  description = "Gitea HTTP 端口"
  type        = number
  default     = 3300
}

variable "gitea_admin_user" {
  description = "自动创建的 Gitea 管理员（实验 18/20/21 复用）"
  type        = string
  default     = "devops"
}

variable "gitea_admin_password" {
  description = "管理员口令（教学靶场弱口令，生产请走密钥管理）"
  type        = string
  default     = "devops123"
  sensitive   = true
}
