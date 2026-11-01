// tb_main.cpp —— gcd 编译模型的 C++ 驱动（verilator --cc --exe）
// 与 tb/tb_gcd.py 同一组向量：握手时序按"eval 前后翻 clk"的 C++ 惯用法还原
#include "Vgcd.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>

struct TV {
    uint32_t a, b, want;
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vgcd dut;
    TV tv[] = {
        {48, 18, 6}, {100, 75, 25}, {17, 5, 1}, {7, 7, 7}, {0, 5, 5}, {270, 192, 6},
    };
    const int N = sizeof(tv) / sizeof(tv[0]);
    int pass = 0;

    for (int k = 0; k < N; k++) {
        dut.clk = 0;
        dut.rst_n = 0;
        dut.in_valid = 0;
        dut.out_ready = 0;
        dut.a_in = tv[k].a;
        dut.b_in = tv[k].b;
        for (int i = 0; i < 2; i++) {  // 复位两拍
            dut.clk = 1; dut.eval(); dut.clk = 0; dut.eval();
        }
        dut.rst_n = 1;
        dut.eval();

        dut.in_valid = 1;
        int guard = 0;
        while (dut.in_ready != 1 && guard++ < 100) {  // 等 IDLE
            dut.clk = 1; dut.eval(); dut.clk = 0; dut.eval();
        }
        dut.clk = 1; dut.eval();  // 接受拍：DUT 锁存 a/b
        dut.in_valid = 0;
        dut.clk = 0; dut.eval();

        guard = 0;
        while (dut.out_valid != 1 && guard++ < 300000) {  // 等结果
            dut.clk = 1; dut.eval(); dut.clk = 0; dut.eval();
        }
        uint32_t got = dut.result;
        dut.out_ready = 1;
        dut.clk = 1; dut.eval();  // 交接拍
        dut.out_ready = 0;
        dut.clk = 0; dut.eval();

        if (got == tv[k].want) {
            pass++;
        } else {
            printf("FAIL gcd(%u,%u) = %u, want %u\n", tv[k].a, tv[k].b, got, tv[k].want);
        }
    }
    printf("{\"vectors\": %d, \"passed\": %d}\n", N, pass);
    return pass == N ? 0 : 1;
}
