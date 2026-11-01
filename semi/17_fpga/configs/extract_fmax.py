#!/usr/bin/env python3
"""extract_fmax.py —— 从 nextpnr-ice40 的 Max frequency 输出提取 fmax 并做门禁。

用法：extract_fmax.py <pnr.log> <约束MHz> <out.json>
nextpnr 输出形如：Max frequency for clock 'clk': 78.12 MHz（PASS/FAIL 随约束）。
门禁：fmax < 约束 → exit 1（时序不达标）。
"""
import json
import re
import sys


def main() -> int:
    log, constraint, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    text = open(log, errors="replace").read()
    # 时钟名可能是 clk 或 clk$SB_IO_IN_$glb_clk（PCF 输入经全局缓冲后改名）
    m = re.search(r"Max frequency for clock '[^']*':\s*([\d.]+)\s*MHz", text)
    if not m:
        # 布线失败时 nextpnr 无该行
        json.dump({"fmax_mhz": None, "constraint_mhz": constraint,
                   "met": False, "error": "no timing report (routing failed?)"},
                  open(out, "w"))
        print(f"fmax: 无时序报告（约束 {constraint}MHz）")
        return 1
    fmax = float(m.group(1))
    met = fmax >= constraint
    json.dump({"fmax_mhz": fmax, "constraint_mhz": constraint, "met": met},
              open(out, "w"))
    print(f"fmax: {fmax} MHz（约束 {constraint}）-> {'PASS' if met else 'FAIL'}")
    return 0 if met else 1

if __name__ == "__main__":
    sys.exit(main())
