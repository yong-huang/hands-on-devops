# =============================================================================
# app.py — 被打包的应用（stdlib 无依赖版；flask 版用于多阶段构建演示）
# =============================================================================
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

NAME = os.environ.get("APP_NAME", "slim-demo")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            body = f"app={NAME} status=ok\n".encode()
            code = 200
        else:
            body = f"hello from {NAME}\n".encode()
            code = 200
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # 静音访问日志
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
