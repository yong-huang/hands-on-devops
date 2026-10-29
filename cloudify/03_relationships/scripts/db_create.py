from cloudify import ctx

ctx.instance.runtime_properties["ip"] = "10.200.0.10"
ctx.instance.runtime_properties["port"] = 5432
ctx.logger.info("database 10.200.0.10:5432 published in runtime properties")
