#!/usr/bin/env python3
"""flaky_hunter.py —— 从回归流水线历史里识别 flaky 种子。

输入：最近 N 条包含 regression 子 job 的流水线（GitLab API）。
分类：
  broken   —— 最近一次运行失败，且历史上从未通过（稳定坏）
  flaky    —— 同一种子在不同流水线里时红时绿（间歇性）
  healthy  —— 最近一次运行通过
输出：flaky_report.json + 控制台摘要。
"""
import json
import sys
from collections import defaultdict

import gitlab


def main() -> int:
    url, token, project_path, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    gl = gitlab.Gitlab(url, private_token=token, retry_transient_errors=True)
    p = gl.projects.get(project_path)

    history = defaultdict(lambda: {"pass": 0, "fail": 0, "pipelines": []})
    scanned = 0
    for pl in p.pipelines.list(get_all=False, per_page=30):  # 全 refs：真实历史分布在 MR 流水线上
        if scanned >= n:
            break
        jobs = p.pipelines.get(pl.id).jobs.list(get_all=True)
        seeds = [j for j in jobs if j.name.startswith("regression: [")]
        if not seeds:
            continue  # 只看含回归矩阵的流水线
        scanned += 1
        for j in seeds:
            seed = j.name.split("[")[1].rstrip("]")
            ok = j.status == "success"
            history[seed]["pass" if ok else "fail"] += 1
            history[seed]["pipelines"].append(f"{pl.iid}:{j.status}")

    report = {"scanned_pipelines": scanned, "seeds": {}}
    flaky, broken = [], []
    for seed in sorted(history, key=int):
        h = history[seed]
        if h["fail"] == 0:
            verdict = "healthy"
        elif h["pass"] == 0:
            verdict = "broken"
        else:
            verdict = "flaky"
            flaky.append(seed)
        if verdict == "broken":
            broken.append(seed)
        report["seeds"][seed] = {"verdict": verdict, **h}
    report["flaky_seeds"] = flaky
    report["broken_seeds"] = broken

    with open("flaky_report.json", "w") as f:
        json.dump(report, f, indent=1)
    for seed in sorted(history, key=int):
        h = history[seed]
        print(f"seed {seed:>2}: pass={h['pass']} fail={h['fail']} "
              f"({'/'.join(h['pipelines'])})")
    print(f"[{'ok' if not flaky else 'warn'}] 扫描 {scanned} 条流水线："
          f"flaky={flaky} broken={broken}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
