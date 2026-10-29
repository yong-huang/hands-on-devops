output "names" {
  value = docker_container.web[*].name
}

output "ports" {
  value = [for c in docker_container.web : c.ports[0].external]
}
