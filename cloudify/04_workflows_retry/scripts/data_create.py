from cloudify import ctx

ctx.instance.runtime_properties["state"] = "ready"
ctx.logger.info("data {} ready".format(ctx.instance.id))
