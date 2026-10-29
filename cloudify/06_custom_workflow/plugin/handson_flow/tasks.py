import time

from cloudify import ctx
from cloudify.decorators import operation


@operation(resumable=True)
def restart(ctx, **kwargs):
    """A restart payload with a fixed 1s "work" window so that serial vs
    parallel execution is measurable from timestamps."""
    started = time.time()
    time.sleep(1)
    ctx.instance.runtime_properties["restart_at"] = started
    ctx.instance.runtime_properties["finished_at"] = time.time()
    ctx.logger.info("restart {} span {:.2f}s".format(
        ctx.instance.id, time.time() - started))


@operation(resumable=True)
def noop(ctx, **kwargs):
    ctx.logger.info("noop on {}".format(ctx.instance.id))
