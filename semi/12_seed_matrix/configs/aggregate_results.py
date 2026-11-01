#!/usr/bin/env python3
"""aggregate_results.py —— 聚合 16 个种子子 job 的 summary_seed_N.json → summary.json。

子 job 的 artifacts 经 needs 自动下载到工作区同路径；逐个找 summary_seed_*.json。
"""
import glob
import json
import sys

def main() -> int:
    files = sorted(glob.glob("sim/summary_seed_*.json"))
    summaries = []
    for f in files:
        summaries.append(json.load(open(f)))
    total = len(summaries)
    failed = [s for s in summaries if s["status"] != "pass"]
    missing = 16 - total
    out = {
        "expected": 16,
        "collected": total,
        "passed": total - len(failed),
        "failed": len(failed),
        "failed_seeds": [str(s["seed"]) for s in failed],
        "missing_seeds": missing,
        "verdict": "pass" if total == 16 and not failed else "fail",
    }
    with open("sim/summary.json", "w") as f:
        json.dump(out, f, indent=1)
    print(f"pass={out['passed']} fail={out['failed']} "
          f"(collected {total}/16, failed_seeds={out['failed_seeds']})")
    return 0 if out["verdict"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
