#!/usr/bin/env python3
"""webhook-listener：记录 GitLab 推来的事件（纯标准库，容器内零 pip 依赖）。

POST /hook    —— 记录一条事件到 /data/events.json（宿主可直接读 volume）
GET  /events  —— 返回已记录事件（JSON 数组）
GET  /health  —— 存活探针
只做记录器，不做系统：为后续项目的「事件可观测」打样（清单项目 4 ⚠️ 风险行的自我约束）。
"""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

EVENTS_FILE = "/data/events.json"


def load_events() -> list:
    try:
        with open(EVENTS_FILE) as f:
            return json.load(f)
    except Exception:
        return []


def save_events(events: list) -> None:
    with open(EVENTS_FILE, "w") as f:
        json.dump(events, f, ensure_ascii=False, indent=1)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes = b"") -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            return self._send(200, b'{"ok":true}')
        if self.path == "/events":
            return self._send(200, json.dumps(load_events()).encode())
        self._send(404, b'{"error":"not found"}')

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except Exception:
            payload = {"object_kind": "?", "raw": body.decode(errors="replace")[:300]}
        events = load_events()
        events.append(
            {
                "time": time.strftime("%FT%T%z"),
                "kind": payload.get("object_kind", "?"),
                "project": (payload.get("project") or {}).get("path_with_namespace", ""),
                "user": (payload.get("user_username") or (payload.get("user") or {}).get("username", "")),
                "ref": payload.get("ref", ""),
                "action": (payload.get("object_attributes") or {}).get("action", ""),
            }
        )
        save_events(events)
        print(f"recorded #{len(events)}: {events[-1]['kind']} {events[-1]['action']} "
              f"by {events[-1]['user']}", flush=True)
        self._send(200, b'{"ok":true}')

    def log_message(self, *args) -> None:  # 静默默认访问日志
        pass


if __name__ == "__main__":
    print("webhook-listener on :9000", flush=True)
    HTTPServer(("0.0.0.0", 9000), Handler).serve_forever()
