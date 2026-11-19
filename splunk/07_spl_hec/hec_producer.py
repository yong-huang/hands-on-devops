#!/usr/bin/env python3
# =============================================================================
# 07 · HEC 批量产生器 — 模拟 web 访问 JSON 事件流
#
# 协议：POST https://<hec>/services/collector/event?channel=<GUID>
#       Authorization: Splunk <token>
#       body = 多行 JSON（每行一个事件对象，一个请求批量带 N 条）
# channel（32 位十六进制通道标识）：useACK=true 的 token 强制要求——不带它
# 请求直接被拒（实测 {"text":"Missing data channel"}）。ackId 回执本脚本
# 不逐批确认（ack 只影响确认语义不影响入库），完整的 ack 回执断言在 spl_hec.sh。
#
# 事件对象：{"time": <epoch 秒>, "event": {...业务字段...},
#            "sourcetype": "splk_hec_json", "index": "hec_demo"}
#   —— time 是"事件时间"：Splunk 用它当 _time，而非接收时刻（timecheck 步骤的对象）
#
# 用法：hec_producer.py --count 10000 --batch 500 --token <TOKEN>
# 输出：JSON 摘要（发送条数/批次/耗时/事件时间范围），供脚本断言。
# =============================================================================
import argparse, json, random, ssl, sys, time, urllib.request, uuid

HEC_URL = "https://localhost:28088/services/collector/event"
PATHS = ["/product.screen", "/category.screen", "/cart.do", "/oldlink", "/checkout"]
CLIENTS = ["87.194.216.51", "211.166.11.101", "128.241.220.82", "10.0.0.7"]

CTX = ssl._create_unverified_context()   # 自签证书


def post_events(payload_lines, token, channel):
    url = f"{HEC_URL}?channel={channel}"
    req = urllib.request.Request(
        url, data="\n".join(payload_lines).encode("utf-8"),
        headers={"Authorization": f"Splunk {token}", "Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req, context=CTX, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=10000)
    ap.add_argument("--batch", type=int, default=500)
    ap.add_argument("--token", required=True)
    ap.add_argument("--base-ts", type=float, default=None,
                    help="事件时间基准（epoch 秒）；缺省=now-5400s，与接收时间拉开 1.5 小时")
    args = ap.parse_args()

    channel = uuid.uuid4().hex
    base_ts = args.base_ts if args.base_ts is not None else time.time() - 5400
    statuses = [200] * 8 + [404, 500]           # 大体成功、少量错误
    sent, batches, failures = 0, 0, 0
    t0 = time.perf_counter()

    for start in range(0, args.count, args.batch):
        end = min(start + args.batch, args.count)
        lines = []
        for i in range(start, end):
            ev = {
                "time": round(base_ts + i * 0.5, 3),      # 事件时间：每 0.5s 一条
                "sourcetype": "splk_hec_json",
                "index": "hec_demo",
                "host": "hec-producer",
                "event": {
                    "seq": i,
                    "path": random.choice(PATHS),
                    "status": random.choice(statuses),
                    "latency_ms": random.randint(5, 400),
                    "clientip": random.choice(CLIENTS),
                },
            }
            lines.append(json.dumps(ev, ensure_ascii=False))
        try:
            resp = post_events(lines, args.token, channel)
            if resp.get("code") != 0:
                failures += 1
                print(f"batch {batches}: HEC 拒绝 {resp}", file=sys.stderr)
                continue
            sent += end - start
            batches += 1
        except Exception as e:                           # 单批失败不中断，计入统计
            failures += 1
            print(f"batch {batches} failed: {e}", file=sys.stderr)

    seconds = time.perf_counter() - t0
    print(json.dumps({
        "channel": channel,
        "sent": sent, "batches": batches, "failures": failures,
        "seconds": round(seconds, 2),
        "base_ts": round(base_ts, 3), "last_ts": round(base_ts + (args.count - 1) * 0.5, 3),
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
