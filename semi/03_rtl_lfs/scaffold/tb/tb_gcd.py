"""tb_gcd.py —— gcd 的 cocotb 冒烟 testbench（项目 3 结构自证；完整参数化仿真在项目 8/9）"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

VECTORS = [
    (48, 18, 6),
    (100, 75, 25),
    (17, 5, 1),
    (7, 7, 7),
    (0, 5, 5),     # gcd(0,b)=b：x=0 先换位再收敛
    (270, 192, 6),
]


async def gcd_op(dut, a, b):
    """发一次请求并等结果握手，返回读到的 result（整数）"""
    dut.a_in.value = a
    dut.b_in.value = b
    dut.in_valid.value = 1
    while int(dut.in_ready.value) != 1:
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)          # 这一拍 DUT 采样 in_valid，锁存 a/b
    dut.in_valid.value = 0
    while int(dut.out_valid.value) != 1:
        await RisingEdge(dut.clk)
    got = int(dut.result.value)
    dut.out_ready.value = 1
    await RisingEdge(dut.clk)          # DUT 采样 out_ready，回到 IDLE
    dut.out_ready.value = 0
    await RisingEdge(dut.clk)
    return got


@cocotb.test()
async def smoke_gcd(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst_n.value = 0
    dut.in_valid.value = 0
    dut.out_ready.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    for a, b, want in VECTORS:
        got = await gcd_op(dut, a, b)
        assert got == want, f"gcd({a},{b}) = {got}, 期望 {want}"
        dut._log.info(f"gcd({a},{b}) = {got} [ok]")
