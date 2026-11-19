#!/usr/bin/env python3
# =============================================================================
# 09 · 测试数据产生器 — 多行异常栈（100 事件）+ 结构化 CSV（50 行）
#
# stack.log：每个事件 = 1 行首行（时间戳/级别/服务/状态）+ 2~4 行缩进栈帧。
#   事件间无空行分隔——切分完全靠 props.conf 的 BREAK_ONLY_BEFORE，这正是
#   多行解析要验证的核心。时间戳逐事件 +1s（base=now-600s，全在过去）。
# rows.csv：首行表头（INDEXED_EXTRACTIONS 依赖）+ 50 行数据，ts 列作时间戳。
#
# 用法：gen_testdata.py --out tmp —— 产出 tmp/stack.log 与 tmp/rows.csv
# 输出：JSON 摘要（事件数/行数/时间范围），供脚本断言。
# =============================================================================
import argparse, json, random, time

FRAMES = ["OrderService.process", "PaymentClient.call", "UserRepo.lookup", "Main.run"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="tmp")
    args = ap.parse_args()

    rnd = random.Random(20261116)
    base = time.time() - 600

    stack_lines, events_meta = [], []
    for i in range(100):
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(base + i))
        svc = rnd.choice(["auth-svc", "order-svc", "pay-svc"])
        level = rnd.choice(["ERROR", "ERROR", "WARN"])
        status = rnd.choice([500, 500, 503])
        head = f"{ts} {level} svc={svc} status={status} {svc}.handle failed"
        n_frames = rnd.randint(2, 4)
        frames = "\n".join(f"\tat com.acme.{f}({f}.java:{rnd.randint(10,200)})"
                           for f in rnd.sample(FRAMES, n_frames))
        stack_lines.append(f"{head}\njava.lang.RuntimeException: injected for lab\n{frames}")
        events_meta.append({"i": i, "ts_epoch": base + i, "level": level,
                            "svc": svc, "status": status})
    open(f"{args.out}/stack.log", "w", encoding="utf-8").write("\n".join(stack_lines) + "\n")

    users = ["alice", "bob", "carol", "dave", "erin"]
    regions = ["cn-north", "cn-east", "cn-south"]
    csv_lines = ["ts,user,action,region,latency_ms"]
    for i in range(50):
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(base + i))
        csv_lines.append(f"{ts},{rnd.choice(users)},{rnd.choice(['login','view','buy'])},"
                         f"{rnd.choice(regions)},{rnd.randint(5,300)}")
    open(f"{args.out}/rows.csv", "w", encoding="utf-8").write("\n".join(csv_lines) + "\n")

    meta = {
        "events": len(events_meta),
        "base_ts": round(base, 3),
        "last_ts": round(base + 99, 3),
        "csv_rows": 50,
    }
    with open(f"{args.out}/prod.json", "w", encoding="utf-8") as f:
        json.dump(meta, f)
    print(json.dumps(meta, ensure_ascii=False))


if __name__ == "__main__":
    main()
