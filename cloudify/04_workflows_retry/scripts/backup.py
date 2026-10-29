import time

from cloudify import ctx

# invoked via the execute_operation built-in workflow against the custom
# handson.interfaces.maintenance.backup operation
ctx.instance.runtime_properties["backup_at"] = time.strftime("%Y%m%dT%H%M%S")
ctx.logger.info("backup of {} done".format(ctx.instance.id))
