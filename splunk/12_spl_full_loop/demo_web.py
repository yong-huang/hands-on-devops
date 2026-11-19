#!/usr/bin/env python3
# =============================================================================
# 🏁 12 · demo-web — 被观测的目标服务（stdlib 实现，零依赖）
#
# 每个请求做两件事（双通道，同一索引 loop_demo）：
#   通道 1  HEC 直报：请求元数据 JSON 推 /services/collector/event
#   通道 2  文件日志：同请求追加一行到 demo_web.log（由 UF 采集）
#
# 用法：demo_web.py --port 28330 --hec-token <TOKEN> --logfile demo_web.log
# 路由：GET /hit 正常请求；GET /boom 500 响应（错误率告警的燃料）；
#       GET /health 健康探针。
# =============================================================================
import argparse, json, random, threading, time, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib import request as urlreq

CHANNEL = uuid.uuid4().hex   # ack 模式强制 32 位 hex 通道（lab 07 同款）

CTX = None  # 延迟创建（自签 HEC 证书）


class DemoWeb(BaseHTTPRequestHandler):
    token = ""
    logfile = ""

    def _log_line(self, text):
        with open(self.logfile, "a", encoding="utf-8") as f:
            f.write(text + "\n")

    def _hec(self, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        req = urlreq.Request(
            f"https://localhost:28088/services/collector/event?channel={CHANNEL}",
            data=body,
            headers={"Authorization": f"Splunk {self.token}",
                     "Content-Type": "application/json"},
            method="POST")
        with urlreq.urlopen(req, context=CTX, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def _serve(self, status):
        i = int(time.time() * 1000) % 1000000
        now = round(time.time(), 3)
        latency = random.randint(5, 120)
        # 通道 1：HEC 直报（事件时间=请求时刻）
        try:
            self._hec({"time": now, "sourcetype": "splk_demo_hec",
                       "index": "loop_demo", "host": "demo-web",
                       "event": {"seq": i, "status": status,
                                 "latency_ms": latency,
                                 "path": self.path, "clientip": "10.9.9.9"}})
        except Exception as e:
            print(f"HEC push failed: {e}", flush=True)
        # 通道 2：文件日志（UF 采集；HEC 失败也照写，两通道独立）
        self._log_line(f'{time.strftime("%Y-%m-%d %H:%M:%S")} [demo-web] '
                       f'seq={i} path={self.path} status={status} '
                       f'latency_ms={latency} clientip=10.9.9.9')
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(f"seq={i} status={status} latency={latency}ms\n".encode())

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"healthy\n")
            return
        if self.path == "/boom":
            self._serve(500)
            return
        self._serve(200)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=28330)
    ap.add_argument("--hec-token", required=True)
    ap.add_argument("--logfile", default="demo_web.log")
    args = ap.parse_args()
    import ssl
    CTX = ssl._create_unverified_context()
    DemoWeb.token = args.hec_token
    DemoWeb.logfile = args.logfile
    random.seed()
    print(f"demo-web on :{args.port}（HEC+文件双通道 → index=loop_demo）", flush=True)
    HTTPServer(("127.0.0.1", args.port), DemoWeb).serve_forever()
