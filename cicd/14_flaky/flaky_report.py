#!/usr/bin/env python3
"""flaky 报告与隔离名单生成。

用法: flaky_report.py <logs-dir> <rounds>
读 detect-<i>.log（pytest -rR 输出），提取 RERUN 过的用例 → quarantine.txt，
并输出人读报告 flaky-report.txt。退出码 0=检出 flaky，1=未检出。
"""
import glob
import os
import re
import sys

logs = sys.argv[1] if len(sys.argv) > 1 else ".logs"
rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 10

# 两种形态都吃：摘要行 "RERUN <nodeid>" 与 -v 行 "<nodeid> RERUN"
pat_a = re.compile(r"RERUN (\S+::\S+)")
pat_b = re.compile(r"(\S+::\S+) RERUN")

flaky = {}          # nodeid -> 发生重试的轮数
red_rounds = 0
rerun_rounds = 0

for i in range(1, rounds + 1):
    path = os.path.join(logs, f"detect-{i}.log")
    if not os.path.exists(path):
        continue
    hits = set()
    for line in open(path, encoding="utf-8", errors="replace"):
        m = pat_a.search(line) or pat_b.search(line)
        if m:
            hits.add(m.group(1))
    if hits:
        rerun_rounds += 1
    for node in hits:
        flaky[node] = flaky.get(node, 0) + 1
    # 重试耗尽仍红的轮（exit 1 由外层记录，这里看摘要行）
    if re.search(r"^\d+ failed", open(path, encoding="utf-8", errors="replace").read(), re.M):
        red_rounds += 1

lines = []
lines.append(f"flaky 检测报告（{rounds} 轮 × reruns=3）")
lines.append(f"  发生重试的轮数: {rerun_rounds}/{rounds}")
lines.append(f"  重试耗尽仍红的轮数: {red_rounds}（flaky 的本质：重试掩盖不了全部）")
lines.append("  检出 flaky 用例（按重试发生轮数排序）:")
for node, cnt in sorted(flaky.items(), key=lambda kv: -kv[1]):
    lines.append(f"    - {node}  ({cnt}/{rounds} 轮重试)")

report = "\n".join(lines) + "\n"
open(os.path.join(logs, "flaky-report.txt"), "w", encoding="utf-8").write(report)
print(report, end="")

with open(os.path.join(logs, "quarantine.txt"), "w", encoding="utf-8") as f:
    for node in sorted(flaky):
        f.write(node + "\n")

sys.exit(0 if flaky else 1)
