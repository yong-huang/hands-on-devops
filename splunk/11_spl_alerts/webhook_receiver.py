#!/usr/bin/env python3
# =============================================================================
# 11 · webhook 接收器 — 记录告警载荷与到达时刻
#
# HTTP POST /notify：把每次送达的 JSON 落成 tmp/webhook_<ts>.json 并打印
# 来源与时间。告警触发间隔断言（3 次调度间隔与 cron 一致）全靠这些时间戳。
# 运行方式：后台进程（spl_lookup.sh 同款），tmp/ 目录为约定交接点。
# =============================================================================
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else "tmp"
PORT = 28321


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
        arrived = time.time()
        try:
            payload = json.loads(body)
        except Exception:
            payload = {"raw": body[:500]}
        record = {"arrived_epoch": round(arrived, 3), "arrived_str": ts,
                  "path": self.path, "payload": payload}
        fname = f"{OUT_DIR}/webhook_{int(arrived*1000)}.json"
        with open(fname, "w", encoding="utf-8") as f:
            json.dump(record, f, ensure_ascii=False, indent=1)
        print(f"[{ts}] POST {self.path} -> {fname} "
              f"(search_name={payload.get('search_name', '?')})", flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok": true}')

    def log_message(self, *a):   # 静默默认访问日志
        pass


if __name__ == "__main__":
    import os
    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"webhook receiver on :{PORT}, 输出目录 {OUT_DIR}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
