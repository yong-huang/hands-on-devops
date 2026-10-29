import os
import time

import requests
from cloudify import ctx
from cloudify.decorators import operation
from cloudify.exceptions import OperationRetry, NonRecoverableError


def _check_http(ctx, **kwargs):
    """Poll `url` until it answers `expect_status`; raise OperationRetry when
    attempts run out (engine re-invokes per operation max_retries)."""
    url = ctx.node.properties["url"]
    expect = ctx.node.properties.get("expect_status", 200)
    max_attempts = ctx.node.properties.get("max_attempts", 5)

    status = 0
    last_error = ""
    for attempt in range(1, max_attempts + 1):
        try:
            resp = requests.get(url, timeout=2)
            status = resp.status_code
        except requests.RequestException as exc:
            last_error = str(exc)
            status = 0
        ctx.logger.info("check_http {}/{} {} -> {}".format(attempt, max_attempts, url, status))
        if status == expect:
            ctx.instance.runtime_properties["status_code"] = status
            return
        time.sleep(1)
    # raising OperationRetry == ctx.operation.retry(msg); raising is testable
    raise OperationRetry("check_http: {} answered {} (expect {}); last_error={}".format(
        url, status, expect, last_error))


@operation(resumable=True)
def check_http(ctx, **kwargs):
    # the @operation wrapper swallows OperationRetry when invoked outside the
    # engine (unit tests call _check_http directly)
    return _check_http(ctx, **kwargs)


@operation(resumable=True)
def render_file(ctx, **kwargs):
    path = ctx.node.properties["path"]
    content = ctx.node.properties.get("content")
    if content is None:
        raise NonRecoverableError("render_file: property 'content' is required")
    with open(path, "w") as f:
        f.write(content)
    ctx.instance.runtime_properties["rendered_path"] = path
    ctx.logger.info("rendered file {} ({} bytes)".format(path, len(content)))


@operation(resumable=True)
def remove_file(ctx, **kwargs):
    path = ctx.instance.runtime_properties.get("rendered_path") \
        or ctx.node.properties.get("path")
    if path and os.path.exists(path):
        os.remove(path)
        ctx.logger.info("removed file {}".format(path))


@operation(resumable=True)
def noop(ctx, **kwargs):
    ctx.logger.info("noop on {}".format(ctx.instance.id))
