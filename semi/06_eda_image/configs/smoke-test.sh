#!/usr/bin/env bash
# eda-base 冒烟：四个工具的版本号全部打印（CI job 与 acceptance 都调它）
set -euo pipefail
echo "verilator: $(verilator --version)"
echo "yosys: $(yosys -V)"
echo "iverilog: $(iverilog -V 2>&1 | head -1)"
python3 -c "import cocotb; print('cocotb:', cocotb.__version__)"
echo "SMOKE_OK"
