#!/usr/bin/env python3
"""license-mock —— EDA 许可证并发令牌服务（纯标准库，模拟 FlexLM 的令牌语义）。

POST /acquire  → 归还 {"lease": "<id>"}；池空则 429 {"error": "no license available"}
POST /release  → body {"lease": "<id>"} 归还
GET  /status   → {"available": N, "pool": P, "leases": [{"lease","holder","expires_in"}]}
GET  /health   → 存活探针

令牌池大小 LICENSE_POOL（默认 3）；租约 TTL LICENSE_TTL 秒（默认 120，模拟 FlexLM
的超时回收——客户端 kill -9 没机会 release，服务端兜底）。
"""
import json
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

POOL = int(open("/config/pool").read().strip()) if __import__("os").path.exists("/config/pool") else 3
TTL = int(open("/config/ttl").read().strip()) if __import__("os").path.exists("/config/ttl") else 120

LOCK = threading.Lock()
LEASES = {}  # lease_id -> {"holder", "expires"}


def sweeper():
    """TTL 兜底回收：客户端异常退出（kill -9）后租约到期自动释放。"""
    while True:
        time.sleep(5)
        with LOCK:
            now = time.time()
            dead = [k for k, v in LEASES.items() if v["expires"] <= now]
            for k in dead:
                print(f"lease {k[:8]} EXPIRED (holder={LEASES[k]['holder']})", flush=True)
                del LEASES[k]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True, "pool": POOL, "ttl": TTL})
        if self.path == "/status":
            with LOCK:
                now = time.time()
                return self._send(200, {
                    "available": POOL - len(LEASES),
                    "pool": POOL,
                    "leases": [{"lease": k[:8], "holder": v["holder"],
                                "expires_in": int(v["expires"] - now)}
                               for k, v in LEASES.items()],
                })
        self._send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            body = {}
        if self.path == "/acquire":
            holder = body.get("holder", "unknown")
            with LOCK:
                if len(LEASES) >= POOL:
                    return self._send(429, {"error": "no license available",
                                            "available": 0})
                lease = uuid.uuid4().hex
                LEASES[lease] = {"holder": holder, "expires": time.time() + TTL}
                print(f"lease {lease[:8]} ACQUIRED (holder={holder}, "
                      f"available={POOL - len(LEASES)})", flush=True)
            return self._send(200, {"lease": lease, "ttl": TTL})
        if self.path == "/release":
            lease = body.get("lease", "")
            with LOCK:
                if lease in LEASES:
                    print(f"lease {lease[:8]} RELEASED (holder={LEASES[lease]['holder']})",
                          flush=True)
                    del LEASES[lease]
                    return self._send(200, {"ok": True})
            return self._send(404, {"error": "lease not found"})
        self._send(404, {"error": "not found"})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    threading.Thread(target=sweeper, daemon=True).start()
    print(f"license-mock on :9001 pool={POOL} ttl={TTL}s", flush=True)
    HTTPServer(("0.0.0.0", 9001), Handler).serve_forever()
