#!/usr/bin/env python3
"""lic.py —— license-mock 客户端（urllib，无第三方依赖）。

用法：
  lic.py acquire <holder>            # 输出 lease id；池空退出码 3
  lic.py release <lease>
  lic.py status                      # 输出 JSON
"""
import json
import sys
import urllib.request

SERVER = __import__("os").environ.get("LICENSE_SERVER", "http://license-mock:9001")


def req(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(SERVER + path, data=data, method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def main() -> int:
    cmd = sys.argv[1]
    if cmd == "acquire":
        code, body = req("/acquire", {"holder": sys.argv[2]})
        if code == 200:
            print(body["lease"])
            return 0
        print(f"no license available ({code})", file=sys.stderr)
        return 3
    if cmd == "release":
        code, _ = req("/release", {"lease": sys.argv[2]})
        return 0 if code == 200 else 1
    if cmd == "status":
        _, body = req("/status")
        print(json.dumps(body))
        return 0
    print(f"unknown cmd {cmd}", file=sys.stderr)
    return 2

if __name__ == "__main__":
    sys.exit(main())
