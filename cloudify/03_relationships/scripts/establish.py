# relationship source operation: runs with BOTH source and target context
from cloudify import ctx

ip = ctx.target.instance.runtime_properties.get("ip")
port = ctx.target.instance.runtime_properties.get("port")
if not ip or not port:
    ctx.abort_operation("target runtime properties missing ip/port")

endpoint = "{}:{}".format(ip, port)
ctx.source.instance.runtime_properties["db_endpoint"] = endpoint
ctx.logger.info("establish: {} <- {} ({})".format(
    ctx.source.instance.id, ctx.target.instance.id, endpoint))
