provider "docker" {}

variable "replicas" {
  type    = number
  default = 1
}

variable "base_port" {
  type    = number
  default = 28112
}

resource "docker_container" "web" {
  count = var.replicas
  name  = "cfy08-web-${count.index}"
  image = "nginx:1.29-alpine"
  ports {
    internal = 80
    external = var.base_port + count.index
  }
}
