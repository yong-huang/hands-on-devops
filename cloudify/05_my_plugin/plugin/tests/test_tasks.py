from unittest import mock

import pytest
from cloudify.exceptions import OperationRetry, NonRecoverableError
from cloudify.mocks import MockCloudifyContext
from cloudify.state import current_ctx

from handson_plugin import tasks


def make_ctx(properties=None, runtime_properties=None):
    ctx = MockCloudifyContext(
        node_id="test-node",
        node_name="test-node",
        properties=properties or {},
        runtime_properties=runtime_properties or {},
        operation={"retry_number": 0},
    )
    current_ctx.set(ctx)
    return ctx


class FakeResponse:
    def __init__(self, status_code):
        self.status_code = status_code


def test_check_http_success_writes_runtime_property():
    ctx = make_ctx(properties={"url": "http://example.test/", "expect_status": 200})
    with mock.patch.object(tasks.requests, "get", return_value=FakeResponse(200)):
        tasks._check_http(ctx=ctx)
    assert ctx.instance.runtime_properties["status_code"] == 200
    current_ctx.clear()


def test_check_http_retries_when_not_ready():
    """first 503 -> OperationRetry (engine-level retry), then 200 -> success"""
    ctx = make_ctx(properties={"url": "http://example.test/", "max_attempts": 2})
    with mock.patch.object(tasks.requests, "get",
                           side_effect=[FakeResponse(503), FakeResponse(503)]), \
            mock.patch.object(tasks.time, "sleep"):
        with pytest.raises(OperationRetry):
            tasks._check_http(ctx=ctx)
    with mock.patch.object(tasks.requests, "get", return_value=FakeResponse(200)):
        tasks._check_http(ctx=ctx)
    assert ctx.instance.runtime_properties["status_code"] == 200
    current_ctx.clear()


def test_render_file_writes_and_records_path(tmp_path):
    target = tmp_path / "rendered.txt"
    ctx = make_ctx(properties={"path": str(target), "content": "hello from plugin"})
    tasks.render_file(ctx=ctx)
    assert target.read_text() == "hello from plugin"
    assert ctx.instance.runtime_properties["rendered_path"] == str(target)
    current_ctx.clear()


def test_render_file_missing_property_is_non_recoverable():
    ctx = make_ctx(properties={"path": "/tmp/x.txt"})  # content missing
    with pytest.raises(NonRecoverableError):
        tasks.render_file(ctx=ctx)
    current_ctx.clear()
