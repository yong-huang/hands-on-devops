#!/usr/bin/env python3
"""run_tests.py —— cocotb 2.x runner API 冒烟入口
cocotb 2.x 移除了旧 Makefile.sim 流程，runner 也拆到了 cocotb_tools 包：
build（iverilog 编译）→ test（跑 tb_gcd）。
用法：python3 run_tests.py   （在仓库根或 sim/ 均可，路径以本文件为锚）
"""
from pathlib import Path
import os
import sys
import xml.etree.ElementTree as ET

from cocotb_tools.runner import get_runner

SIM_DIR = Path(__file__).resolve().parent
RTL_DIR = SIM_DIR.parent / "rtl"
TB_DIR = SIM_DIR.parent / "tb"


def main() -> int:
    # tb 在仓库的 tb/ 目录；runner 会用"本进程 sys.path"重写子进程 PYTHONPATH
    # （cocotb_tools/runner.py: env["PYTHONPATH"]=os.pathsep.join(sys.path)），
    # 所以把 tb 目录插进 sys.path 才能被仿真进程 import，extra_env 反而不生效
    sys.path.insert(0, str(TB_DIR))
    runner = get_runner("icarus")
    runner.build(
        verilog_sources=[str(RTL_DIR / "gcd.v")],
        hdl_toplevel="gcd",
        build_dir=str(SIM_DIR / "sim_build"),
        always=True,
    )
    results_xml = runner.test(
        hdl_toplevel="gcd",
        test_module="tb_gcd",
        build_dir=str(SIM_DIR / "sim_build"),
        results_xml=str(SIM_DIR / "results.xml"),
    )
    # ⚠️ cocotb 2.1.0 runner 在仿真器 import 失败时仍返回 0——成败只能看 results.xml
    suite = ET.parse(results_xml).getroot().find("testsuite")
    tests = int(suite.get("tests", 0))
    bad = int(suite.get("failures", 0)) + int(suite.get("errors", 0))
    print(f"smoke: tests={tests} failures={suite.get('failures')} errors={suite.get('errors')}")
    if tests == 0 or bad > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
