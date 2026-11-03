# webhook 接收器：记录 Alertmanager 的 POST（供断言"告警真实送达"）
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = "/data/alerts.json"

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            alerts = json.loads(body)
        except Exception:
            alerts = {"raw": body.decode(errors="replace")}
        try:
            prev = json.load(open(LOG))
        except Exception:
            prev = []
        prev.extend(alerts.get("alerts", [alerts]))
        json.dump(prev, open(LOG, "w"))
        self.send_response(200); self.end_headers()

    def do_GET(self):
        try:
            n = len(json.load(open(LOG)))
        except Exception:
            n = 0
        self.send_response(200); self.end_headers()
        self.wfile.write(str(n).encode())

    def log_message(self, *a): pass

HTTPServer(("0.0.0.0", 9000), H).serve_forever()
