from cloudify import ctx

ctx.logger.info("fatal: unrecoverable condition detected, aborting without retry")
ctx.abort_operation("fatal: unrecoverable condition detected")
