#!/usr/bin/env python3
"""create_bucket_stdlib.py — 纯标准库实现 S3 CreateBucket（AWS SigV4 签名）

动机：minio/mc 镜像在受限网络拉不到时，桶的创建不必依赖任何镜像——
SigV4 就是普通的 HMAC-SHA256 计算链，stdlib 的 hmac/hashlib 足够。

用法: create_bucket_stdlib.py <endpoint> <bucket> [access_key] [secret_key]
例:   create_bucket_stdlib.py http://localhost:9100 tfstate minioadmin minioadmin
"""
import hashlib
import hmac
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

# 本地 MinIO 流量绝不能走系统代理（urllib 会继承 macOS 系统代理，
# 代理去连它自己视角的 localhost → 502 Bad Gateway）
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def create_bucket(endpoint, bucket, ak, sk, region="us-east-1"):
    host = endpoint.split("//")[1]
    path = f"/{bucket}"
    now = datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(b"").hexdigest()

    canonical = "\n".join([
        "PUT", path, "",
        f"host:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n",
        "host;x-amz-content-sha256;x-amz-date",
        payload_hash,
    ])
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amz_date, scope,
        hashlib.sha256(canonical.encode()).hexdigest(),
    ])
    k = sign(sign(sign(sign(("AWS4" + sk).encode(), date_stamp), region), "s3"), "aws4_request")
    sig = hmac.new(k, string_to_sign.encode(), hashlib.sha256).hexdigest()

    req = urllib.request.Request(
        endpoint + path, method="PUT", data=b"",
        headers={
            "Host": host,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amz_date,
            "Authorization": (f"AWS4-HMAC-SHA256 Credential={ak}/{scope}, "
                              f"SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                              f"Signature={sig}"),
        },
    )
    try:
        with OPENER.open(req, timeout=10) as r:
            print(f"[ok] bucket {bucket} created (HTTP {r.status})")
    except urllib.error.HTTPError as e:
        if e.code == 409:  # BucketAlreadyOwnedByYou：幂等复跑
            print(f"[ok] bucket {bucket} already exists (HTTP 409)")
        else:
            raise


if __name__ == "__main__":
    ep, bk = sys.argv[1], sys.argv[2]
    ak = sys.argv[3] if len(sys.argv) > 3 else "minioadmin"
    sk = sys.argv[4] if len(sys.argv) > 4 else "minioadmin"
    create_bucket(ep, bk, ak, sk)
