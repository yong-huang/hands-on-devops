#!/usr/bin/env python3
"""slurm-mock —— HPC 队列模拟器（stdlib）：sbatch/squeue/sacct 语义 + FIFO + 并发上限。

POST /sbatch  body {"name", "script"} → {"job_id"}；script 会在本容器 bash 执行（模拟 compute 节点）
GET  /squeue  → [{"job_id","name","state"}]（PENDING/RUNNING）
GET  /sacct?job_id= → {"state": "COMPLETED|FAILED|RUNNING|PENDING", "exit_code"}
GET  /output?job_id= → 作业 stdout（COMPLETED 后可取）
并发上限 MAX_RUNNING（默认 2，模拟 2 个 compute 节点）；FIFO 队列调度。
"""
import json
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

MAX_RUNNING = 2
OUTDIR = Path("/data"); OUTDIR.mkdir(exist_ok=True)

LOCK = threading.Lock()
JOBS = {}  # job_id -> {"name","script","state","exit_code","output"}


def worker():
    while True:
        time.sleep(0.5)
        with LOCK:
            pending = [j for j in JOBS.values() if j["state"] == "PENDING"]
            running = sum(1 for j in JOBS.values() if j["state"] == "RUNNING")
            slot = MAX_RUNNING - running
            todo = pending[:max(0, slot)]
            for j in todo:
                j["state"] = "RUNNING"
        for j in todo:
            out_path = OUTDIR / f"{j['job_id']}.out"
            try:
                r = subprocess.run(["bash", "-c", j["script"]],
                                   capture_output=True, text=True, timeout=300)
                j["exit_code"] = r.returncode
                out_path.write_text(r.stdout + r.stderr)
                j["state"] = "COMPLETED" if r.returncode == 0 else "FAILED"
            except Exception as e:  # 超时等
                out_path.write_text(str(e))
                j["state"] = "FAILED"
            j["output"] = str(out_path)
            print(f"job {j['job_id']} {j['state']}", flush=True)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True, "max_running": MAX_RUNNING})
        if self.path == "/squeue":
            with LOCK:
                return self._send(200, [
                    {"job_id": j["job_id"], "name": j["name"], "state": j["state"]}
                    for j in JOBS.values() if j["state"] in ("PENDING", "RUNNING")])
        if self.path.startswith("/sacct"):
            jid = self.path.split("job_id=")[-1]
            with LOCK:
                j = JOBS.get(jid)
                if not j:
                    return self._send(404, {"error": "no such job"})
                return self._send(200, {"job_id": jid, "name": j["name"],
                                        "state": j["state"],
                                        "exit_code": j.get("exit_code")})
        if self.path.startswith("/output"):
            jid = self.path.split("job_id=")[-1]
            p = OUTDIR / f"{jid}.out"
            if p.exists():
                return self._send(200, {"output": p.read_text()})
            return self._send(404, {"error": "output not ready"})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/sbatch":
            jid = uuid.uuid4().hex[:8]
            with LOCK:
                JOBS[jid] = {"job_id": jid, "name": body.get("name", "job"),
                             "script": body.get("script", "true"),
                             "state": "PENDING", "exit_code": None}
            print(f"sbatch {jid} ({body.get('name')})", flush=True)
            return self._send(200, {"job_id": jid})
        self._send(404, {"error": "not found"})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    threading.Thread(target=worker, daemon=True).start()
    print(f"slurm-mock on :9002 max_running={MAX_RUNNING}", flush=True)
    HTTPServer(("0.0.0.0", 9002), Handler).serve_forever()
