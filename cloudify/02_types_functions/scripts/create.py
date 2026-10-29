# script plugin (python flavour): full ctx API for property access
from cloudify import ctx

props = ctx.node.properties
config = props.get("config") or {}
ctx.logger.info(
    "static worker_name={}, config.name={}, config.workers={}".format(
        props.get("worker_name"), config.get("name"), config.get("workers")
    )
)

# overwrite the same-named key that get_property reads statically:
# outputs can now show both worlds for one key
ctx.instance.runtime_properties["worker_name"] = "runtime-{}".format(ctx.instance.id)
ctx.instance.runtime_properties["reported_workers"] = config.get("workers")
