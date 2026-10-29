from cloudify import ctx

ctx.instance.runtime_properties["host_id"] = ctx.instance.id
ctx.logger.info("host {} up".format(ctx.instance.id))
