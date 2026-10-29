provider "docker" {}

# TF owns the substrate: a private network and the api container on it.
resource "docker_network" "finale" {
  name = "cfy16-net"
}

resource "docker_container" "api" {
  name    = "cfy16-api"
  image   = "nginx:1.29-alpine"
  network_mode = docker_network.finale.name
  ports {
    internal = 80
    external = 28131
  }
}

resource "docker_container" "unused_volume_guard" {
  count      = 0
  name       = "cfy16-guard-${count.index}"
  image      = "nginx:1.29-alpine"
}
