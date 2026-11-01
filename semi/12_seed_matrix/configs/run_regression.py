#!/usr/bin/env python3
"""run_regression.py —— 种子回归 runner：cocotb runner 跑 tb_random，出 results.xml + summary_seed_N.json。

成败以 results.xml 为准（runner 假成功陷阱，见 P3）；summary 供聚合器消费。
"""
from pathlib import Path
import os
import sys
import json
import xml.etree.ElementTree as ET

from cocotb_tools.runner import get_runner

SIM_DIR = Path(__file__).resolve().parent
RTL_DIR = SIM_DIR.parent / "rtl"
TB_DIR = SIM_DIR.parent / "tb"


def main() -> int:
    seed = os.environ.get("SEED", "0")
    sys.path.insert(0, str(TB_DIR))
    runner = get_runner("icarus")
    runner.build(
        verilog_sources=[str(RTL_DIR / "gcd.v")],
        hdl_toplevel="gcd",
        build_dir=str(SIM_DIR / f"sim_build_s{seed}"),
        always=True,
    )
    results_xml = runner.test(
        hdl_toplevel="gcd",
        test_module="tb_random",
        build_dir=str(SIM_DIR / f"sim_build_s{seed}"),
        results_xml=str(SIM_DIR / f"results_seed_{seed}.xml"),
        extra_env={"SEED": seed},
    )
    suite = ET.parse(results_xml).getroot().find("testsuite")
    tests = int(suite.get("tests", 0))
    bad = int(suite.get("failures", 0)) + int(suite.get("errors", 0))
    passed = tests - bad
    summary = {"seed": seed, "tests": tests, "passed": passed, "failed": bad,
               "status": "pass" if bad == 0 and tests > 0 else "fail"}
    with open(SIM_DIR / f"summary_seed_{seed}.json", "w") as f:
        json.dump(summary, f)
    print(f"seed {seed}: {summary['status']} ({passed}/{tests})")
    return 0 if summary["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
