from cloudify import ctx

ctx.instance.runtime_properties["role"] = "web"
ctx.logger.info("app {} role=web".format(ctx.instance.id))
