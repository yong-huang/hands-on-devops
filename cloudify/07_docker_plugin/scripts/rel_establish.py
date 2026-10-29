# establish source operation: resolve the api container's docker-bridge IP from
# its runtime properties (the plugin stores the long container id under
# `container`; container_info is only a repr string) and publish the in-docker
# endpoint on the web instance.
import docker as docker_sdk
from cloudify import ctx
from cloudify.exceptions import NonRecoverableError

target_props = ctx.target.instance.runtime_properties
container_id = target_props.get("container")
if not container_id:
    raise NonRecoverableError(
        "target instance has no 'container' runtime property: {}".format(
            sorted(target_props.keys())))

client = docker_sdk.DockerClient(base_url="unix:///var/run/docker.sock")
attrs = client.containers.get(container_id).attrs
ns = attrs.get("NetworkSettings") or {}
# OrbStack keeps IPs under Networks.<net>.IPAddress; the top-level
# IPAddress field is None there
ip = ns.get("IPAddress")
if not ip:
    for net in (ns.get("Networks") or {}).values():
        ip = net.get("IPAddress")
        if ip:
            break
if not ip:
    raise NonRecoverableError("api container has no bridge IP (running?)")

host_ports = (target_props.get("container_args") or {}).get("ports") or {}
ctx.source.instance.runtime_properties["backend_endpoint"] = "{}:80".format(ip)
ctx.source.instance.runtime_properties["backend_container_id"] = container_id[:12]
ctx.source.instance.runtime_properties["backend_host_ports"] = host_ports
ctx.logger.info("establish: web -> api in-docker {} (host ports {})".format(
    ip, host_ports))
