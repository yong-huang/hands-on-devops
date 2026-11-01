"""tb_random.py —— 种子化随机回归 testbench（每种子 32 组随机向量，对拍 Python 欧几里得参考模型）。

SEED 环境变量由 parallel:matrix 注入；同一 SEED 的向量序列确定（可复现失败）。
"""
import math
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

N_VECTORS = 32


async def gcd_op(dut, a, b):
    dut.a_in.value = a
    dut.b_in.value = b
    dut.in_valid.value = 1
    while int(dut.in_ready.value) != 1:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    while int(dut.out_valid.value) != 1:
        await RisingEdge(dut.clk)
    got = int(dut.result.value)
    dut.out_ready.value = 1
    await RisingEdge(dut.clk)
    dut.out_ready.value = 0
    await RisingEdge(dut.clk)
    return got


@cocotb.test()
async def random_regression(dut):
    seed = int(os.environ.get("SEED", "0"))
    rng = random.Random(seed)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.in_valid.value = 0
    dut.out_ready.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    fails = []
    for i in range(N_VECTORS):
        a = rng.randint(0, 65535)
        b = rng.randint(0, 65535)
        want = math.gcd(a, b)
        got = await gcd_op(dut, a, b)
        if got != want:
            fails.append((i, a, b, got, want))
            dut._log.error(f"seed={seed} vec#{i}: gcd({a},{b})={got}, want {want}")
    assert not fails, f"seed={seed}: {len(fails)}/{N_VECTORS} 组失败"
