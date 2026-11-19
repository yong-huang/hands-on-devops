#!/usr/bin/env python3
# =============================================================================
# 04 · 双口径对照（crosscheck）
#
# 同一份 access 日志，两个独立实现各算一遍三问：
#   Python 端：直接逐行正则解析 tmp/tut/www*/access.log（不经过 Splunk）
#   Splunk 端：bash 预取的 SPL oneshot 结果（tmp/spl_raw.json）
# 对比断言：每小时桶 / Top10 来源 / 404 占比（总体+逐日）误差 ≤ 1%。
#
# 用法：crosscheck.py --raw tmp/spl_raw.json --files tmp/tut
# 退出码：0 = 全过，1 = 存在超差项。
# =============================================================================
import argparse, glob, json, re, sys
from collections import Counter
from datetime import datetime, timezone

SPAN_12H = 43200   # Q1 分桶：12 小时
SPAN_1D = 86400    # Q3 趋势：1 天
TOL = 0.01         # 容差 1%

# access_combined_wcookie：clientip - - [ts] "req" status bytes ...
LINE_RE = re.compile(r'^(\S+) \S+ \S+ \[([^\]]+)\] "[^"]*" (\d+) (\d+) ')
TS_FMT = "%d/%b/%Y:%H:%M:%S"


def parse_files(pattern):
    """逐行正则解析 → (clientip, epoch, status) 列表；顺带统计跳过行。"""
    events, skipped = [], 0
    for path in sorted(glob.glob(pattern)):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = LINE_RE.match(line)
                if not m:
                    skipped += 1
                    continue
                ip, ts, status = m.group(1), m.group(2), int(m.group(3))
                epoch = datetime.strptime(ts, TS_FMT).replace(
                    tzinfo=timezone.utc).timestamp()   # 容器 TZ=UTC，与 Splunk 同口径
                events.append((ip, epoch, status))
    return events, skipped


def py_metrics(events):
    q1 = Counter(int(e // SPAN_12H) * SPAN_12H for _, e, _ in events)
    q2 = Counter(ip for ip, _, _ in events).most_common(10)
    total = len(events)
    nf = sum(1 for _, _, s in events if s == 404)
    q3 = {"total": total, "nf": nf,
          "pct": round(nf / total * 100, 4) if total else 0.0}
    day_nf, day_total = Counter(), Counter()
    for _, e, s in events:
        d = int(e // SPAN_1D) * SPAN_1D
        day_total[d] += 1
        if s == 404:
            day_nf[d] += 1
    q3c = {d: {"nf": day_nf.get(d, 0), "total": n,
               "pct": round(day_nf.get(d, 0) / n * 100, 4)}
           for d, n in day_total.items()}
    return {"q1": dict(q1), "q2": dict(q2), "q3": q3, "q3c": q3c}


def spl_metrics(raw):
    out = {}
    rows = raw["q1"]["results"]
    out["q1"] = {int(datetime.strptime(r["_time"][:19], "%Y-%m-%dT%H:%M:%S")
                     .replace(tzinfo=timezone.utc).timestamp()): int(r["count"])
                 for r in rows}
    out["q2"] = {r["clientip"]: int(r["count"]) for r in raw["q2"]["results"]}
    r3 = raw["q3"]["results"][0]
    out["q3"] = {"total": int(r3["total"]), "nf": int(r3["nf"]),
                 "pct": float(r3["pct"])}
    out["q3c"] = {}
    for r in raw["q3c"]["results"]:
        d = int(datetime.strptime(r["_time"][:19], "%Y-%m-%dT%H:%M:%S")
                .replace(tzinfo=timezone.utc).timestamp())
        out["q3c"][d] = {"nf": int(r["nf"]), "total": int(r["total"]),
                         "pct": float(r["pct"])}
    return out


def diff_report(name, a, b, tol=TOL):
    """相对误差 |a-b|/max(a,1)，返回 (ok, 描述)。"""
    if a == 0 and b == 0:
        return True, "0 vs 0"
    err = abs(a - b) / max(abs(a), abs(b), 1)
    return err <= tol, f"{a} vs {b}（误差 {err*100:.3f}%）"


def compare(py, sp):
    fails = []

    # Q1：桶数一致 + 每桶计数 ≤1%
    if set(py["q1"]) != set(sp["q1"]):
        fails.append(f"Q1 分桶网格不一致：py {len(py['q1'])} 桶 vs spl {len(sp['q1'])} 桶")
    else:
        bad = [k for k in py["q1"]
               if not diff_report("q1", py["q1"][k], sp["q1"][k])[0]]
        ok = not bad and len(py["q1"]) >= 13
        print(f"  Q1 每小时趋势：{len(py['q1'])} 桶全对比 "
              f"{'✅' if ok else '❌ ' + str(bad[:3])}")
        if not ok:
            fails.append("Q1 桶计数超差")

    # Q2：Top10 集合一致 + 计数 ≤1%
    same_ips = set(py["q2"]) == set(sp["q2"])
    bad = [ip for ip in py["q2"] if ip in sp["q2"]
           and not diff_report("q2", py["q2"][ip], sp["q2"][ip])[0]]
    ok = same_ips and not bad
    print(f"  Q2 Top10 来源：IP 集合{'一致' if same_ips else '不一致'}，"
          f"计数对比 {'✅' if not bad else '❌ ' + str(bad[:3])}")
    if not ok:
        fails.append("Q2 Top10 超差")

    # Q3：404 占比 ≤1%
    ok, desc = diff_report("q3.pct", py["q3"]["pct"], sp["q3"]["pct"])
    print(f"  Q3 404 占比：py {py['q3']['pct']}% vs spl {sp['q3']['pct']}% "
          f"（总量 py {py['q3']['total']} / spl {sp['q3']['total']}）"
          f"{'✅' if ok else '❌'}")
    if not ok:
        fails.append(f"Q3 占比超差：{desc}")

    # Q3c：逐日占比 ≤1%
    if set(py["q3c"]) != set(sp["q3c"]):
        fails.append("Q3c 逐日网格不一致")
    else:
        bad = [d for d in py["q3c"]
               if not diff_report("q3c", py["q3c"][d]["pct"], sp["q3c"][d]["pct"])[0]]
        ok = not bad
        print(f"  Q3c 逐日 404 占比：{len(py['q3c'])} 天 "
              f"{'✅' if ok else '❌ ' + str(bad[:3])}")
        if not ok:
            fails.append("Q3c 逐日超差")

    return fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True, help="bash 预取的 SPL 结果 JSON")
    ap.add_argument("--files", required=True, help="解包后的教程数据目录")
    args = ap.parse_args()

    events, skipped = parse_files(args.files + "/www*/access.log")
    print(f"Python 端：解析 {len(events)} 行（跳过 {skipped} 行非标准行）")
    py = py_metrics(events)
    sp = spl_metrics(json.load(open(args.raw, encoding="utf-8")))
    fails = compare(py, sp)
    if fails:
        print("\n❌ 超差项：" + "；".join(fails))
        sys.exit(1)
    print("\n✅ 三问双口径全部对齐（容差 1%）")


if __name__ == "__main__":
    main()
