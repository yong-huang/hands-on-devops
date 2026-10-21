#!/usr/bin/env python3
"""s3_client.py — 纯标准库的迷你 S3 客户端（AWS SigV4，无第三方依赖）

动机：tf03 实验的 S3 操作原本依赖 minio/mc 镜像；受限网络拉不到镜像时
整条流程卡死。SigV4 就是 HMAC-SHA256 计算链，stdlib 的 hmac/hashlib
足够覆盖本实验用到的四个操作。

用法:
  s3_client.py mb   <endpoint> <bucket>                  # 建桶（幂等）
  s3_client.py rm   <endpoint> <bucket> <prefix>         # 递归删前缀下所有对象
  s3_client.py cat  <endpoint> <bucket> <key>            # 输出对象内容
  s3_client.py pipe <endpoint> <bucket> <key>            # 从 stdin 写对象
"""
import hashlib
import hmac
import json
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

REGION = "us-east-1"

# 本地 MinIO 流量绝不能走系统代理（macOS 系统代理会被 urllib 自动继承，
# 代理去连它自己视角的 localhost → 502 Bad Gateway）
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def request(method, host, bucket, key="", body=b"", ak="minioadmin",
            sk="minioadmin", ok=(200, 204, 404)):
    now = datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()
    path = f"/{bucket}" + (f"/{key}" if key else "")
    canonical_headers = f"host:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical = "\n".join([method, path, "", canonical_headers, signed_headers, payload_hash])
    scope = f"{date_stamp}/{REGION}/s3/aws4_request"
    sts = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                     hashlib.sha256(canonical.encode()).hexdigest()])
    k = sign(sign(sign(sign(("AWS4" + sk).encode(), date_stamp), REGION), "s3"), "aws4_request")
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        f"http://{host}{path}", method=method, data=body or None,
        headers={"Host": host, "x-amz-content-sha256": payload_hash,
                 "x-amz-date": amz_date,
                 "Authorization": (f"AWS4-HMAC-SHA256 Credential=minioadmin/{scope}, "
                                   f"SignedHeaders={signed_headers}, Signature={sig}")})
    try:
        with OPENER.open(req, timeout=15) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        if e.code in ok:
            return e.code, b""
        raise


def main():
    cmd = sys.argv[1]
    host = sys.argv[2].split("//")[-1]  # 容忍传入带 scheme 的 URL
    bucket = sys.argv[3]
    if cmd == "mb":
        status, _ = request("PUT", host, bucket, ok=(200, 201, 409))
        print(f"[ok] bucket {bucket} (HTTP {status})"
              + ("（409 = 已存在，幂等）" if status == 409 else ""))
    elif cmd == "rm":  # 递归删前缀
        prefix = sys.argv[4].rstrip("/") + "/"
        status, body = request("GET", host, bucket,
                               ok=(200, 404), )  # ListObjectsV2
        if status == 404:
            print("[ok] bucket 不存在，无需清理"); return
        keys = [c.text for c in ET.fromstring(body).iter()
                if c.tag.endswith("Key") and c.text and c.text.startswith(prefix)]
        for k in keys:
            request("DELETE", host, bucket, k, ok=(204, 404))
        print(f"[ok] 清理 {len(keys)} 个对象（prefix={prefix}）")
    elif cmd == "cat":
        status, body = request("GET", host, bucket, sys.argv[4], ok=(200, 404))
        sys.stdout.write(body.decode(errors="replace"))
    elif cmd == "pipe":
        body = sys.stdin.buffer.read()
        status, _ = request("PUT", host, bucket, sys.argv[4], body=body, ok=(200,))
        print(f"[ok] 上传 {bucket}/{sys.argv[4]}（{len(body)} 字节）", file=sys.stderr)
    else:
        sys.exit(f"未知子命令: {cmd}")


if __name__ == "__main__":
    main()
