#!/usr/bin/env python3
"""verilator2codequality.py —— 把 verilator lint 输出转成 GitLab Code Quality JSON。

用法：verilator2codequality.py <lint.log> <codequality.json>
GitLab codequality 格式（MR widget 的 "Code Quality" 区块吃这个）：
[{"description","check_name","fingerprint","severity","location":{"path","lines":{"begin"}}}]
fingerprint 用 sha256(path:line:msg)——同一条告警在多次运行间保持稳定，GitLab 靠它做"新增/修复" diff。
"""
import hashlib
import json
import re
import sys

# %Warning-XXX: path:line: message 形如 %Warning-DECLFILENAME: rtl/gcd.v:12: Signal ...
PAT = re.compile(r"%Warning[^:]*:\s*([^:]+):(\d+):\s*(.+)")

def main() -> int:
    log_path, out_path = sys.argv[1], sys.argv[2]
    entries = []
    for line in open(log_path, errors="replace"):
        m = PAT.search(line)
        if not m:
            continue
        path, lineno, msg = m.group(1), int(m.group(2)), m.group(3).strip()
        fp = hashlib.sha256(f"{path}:{lineno}:{msg}".encode()).hexdigest()
        entries.append(
            {
                "description": msg,
                "check_name": "verilator-lint",
                "fingerprint": fp,
                "severity": "major",
                "location": {"path": path, "lines": {"begin": lineno}},
            }
        )
    with open(out_path, "w") as f:
        json.dump(entries, f, ensure_ascii=False, indent=1)
    print(f"codequality: {len(entries)} 条告警")
    return 0

if __name__ == "__main__":
    sys.exit(main())
