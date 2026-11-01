#!/usr/bin/env python3
"""queue_client.py —— GitLab job 视角的队列客户端：sbatch 提交 → sacct 轮询 → 取回输出。

用法：queue_client.py <slurm_url> <job_name> <script> [timeout_s=600]
行为：sbatch 提交 → 每 5s sacct 轮询终态 → /output 取回 stdout → 透传退出码。
Slurm 语义映射：sbatch/squeue/sacct/output ↔ 本模拟器的四个端点（1:1，换真 Slurm 只改这一层）。
"""
import sys
import time
import json
import urllib.request


def call(url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    with urllib.request.urlopen(r, timeout=15) as resp:
        return json.loads(resp.read())


def main() -> int:
    url, name, script = sys.argv[1], sys.argv[2], sys.argv[3]
    timeout = int(sys.argv[4]) if len(sys.argv) > 4 else 600
    jid = call(f"{url}/sbatch", {"name": name, "script": script})["job_id"]
    print(f"sbatch -> job {jid}")
    t0 = time.time()
    while True:
        st = call(f"{url}/sacct?job_id={jid}")["state"]
        print(f"  sacct: {st} ({int(time.time()-t0)}s)", flush=True)
        if st in ("COMPLETED", "FAILED"):
            break
        if time.time() - t0 > timeout:
            print("queue timeout")
            return 2
        time.sleep(5)
    out = call(f"{url}/output?job_id={jid}")["output"]
    print("---- job output ----")
    print(out)
    print("--------------------")
    return 0 if st == "COMPLETED" else 1


if __name__ == "__main__":
    sys.exit(main())
