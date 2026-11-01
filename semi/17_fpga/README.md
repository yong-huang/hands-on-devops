# 17 · FPGA 综合流水线：yosys + nextpnr-ice40 到 bitstream

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 17 · 阶段五「构建、制品与发布」
> rtl-gcd 装上 fpga stage：yosys 综合 → nextpnr-ice40 布线（fmax 时序门禁）→ icepack 出比特流
> 验收在 `fpga.sh verify`：50MHz 绿 + bitstream 归档 / 200MHz 约束红，全过打 `[ok]`

## Background

RTL 仿真全绿只代表"逻辑对"；上 FPGA 还要过**物理实现**——综合（yosys 转网表）、布线（nextpnr 摆进真实器件）、时序（实际能跑多快）。

这一步把"软件意义的对"变成"硅上可跑"，且多出一个新的失败维度：**时序**——RTL 写得再对，布线后跑不到约束频率就是红。CI 的角色是把这条链自动化，并把 fmax 变成门禁。

工具链选择：iCE40HX8K（Lattice）是开源工具链支持最完整的器件（yosys synth_ice40 + nextpnr-ice40 + icestorm），全部可进 CI。

## What

心智模型一句话：**FREQ_MHZ 是给 nextpnr 的军令状——布线完它告诉你实际能跑多快，达不到即红**。

| 步骤 | 工具 | 产物 | 门禁 |
|:---|:---|:---|:---|
| 综合 | yosys synth_ice40 | top.json（网表） | - |
| 布线 | nextpnr-ice40 --hx8k --freq N | top.asc + Max frequency 报告 | fmax ≥ N（extract_fmax.py 解析） |
| 打包 | icepack | top.bin（比特流） | - |

实测基线：gcd 在 hx8k 上 fmax ≈ **120.8MHz**——50/120MHz 约束绿，200MHz 红。验证方法：`./fpga.sh verify` 两段约束循环。

## When to Use

| 场景 | 做法 |
|:---|:---|
| RTL 改动后的可综合性/时序回归 | 本实验：MR 流水线里跑全流程 |
| 频率约束收紧 | 改 syn/Makefile 的 FREQ_MHZ——fmax 门禁自动变严 |
| 换目标器件 | Makefile 的 --hx8k/--package 与 synth_ice40 参数同步换 |
| 真流片流程 | 概念同构（综合→布局布线→时序签核），工具换商用 PDK——门禁思想不变 |

## Quick Start

前置：项目 8-11 完成。

```bash
./fpga.sh up       # 推 fpga stage + syn/{Makefile, gcd.pcf, extract_fmax.py}
./fpga.sh verify   # 50 绿 + 200 红（约 10 分钟，两轮全流水线）
./fpga.sh status   # 最近流水线
```

`verify` 的真实输出（实测，全过）：

```
=====> [verify1] 50MHz 约束 → fmax ≥ 50 绿 + bitstream 产出
  [ok]   50MHz 流水线 success（#177）
  [ok]   fmax.json 有效且 ≥ 50MHz
  [ok]   bitstream（.bin）在归档中
=====> [verify2] 200MHz 约束 → 时序失败红（实测 fmax≈120.8MHz，120 仍在裕量内）
  [ok]   200MHz 流水线 failed（时序不达标被门禁拦截）

[ok] 项目 17 全部验收断言通过
```

## How It Works

### fmax 门禁的实现

nextpnr 布线完成时输出 `Max frequency for clock 'xxx': N MHz (PASS/FAIL at 约束)`——extract_fmax.py 用正则提取。

**时钟名要按 `[^']*` 通配**：PCF 输入时钟经全局缓冲后改名为 `clk$SB_IO_IN_$glb_clk`，写死 'clk' 匹配不到。门禁 `met = fmax >= constraint` 写进 fmax.json，make 据此定退出码。

### 工具链进 CI 的两条路

native 工具链（brew/apt）进镜像最直接，但 ice40 后端不在 Ubuntu 主源、源码编译重。

本实验走 **yowasp**（WASM 版 yosys/nextpnr/icepack，pip 装即用、跨平台结果一致——本地 native 与 CI 的 WASM 算出完全相同的 fmax 120.79）。

CI 里 `pip install --target .yowasp-tools` + cache 缓存 + PATH/PYTHONPATH 双导出——--target 目录要同时进 PATH 和 PYTHONPATH，bin 脚本才能找到包。

### 管脚约束的教训

ct256 封装的管脚名是**封装网格坐标**（B1/C14），不是数字。PCF 写错时 nextpnr 报 `package does not have a pin named 'X'`，且部分"数字名"单测能过、组合后失败（网格位实为电源/配置脚）。

解法：逐信号探测脚本自动分配合法管脚（本实验的 PCF 即探测产物）。

## Pitfalls & Q&A

**坑 1：CI 变量覆盖 sed。** yml 里 `variables: FREQ_MHZ: "50"` + `make FREQ_MHZ=$FREQ_MHZ`——make 命令行参数优先于 Makefile 内赋值，sed 修改被完全架空（200MHz 跑成 50MHz 还绿着）。

修法：删 CI 变量，`make` 裸跑，频率只在 Makefile。

**坑 2：`make FREQ_MHZ=`（空展开）穿透默认值。** CI 变量删除后 `$FREQ_MHZ` 展开为空，`make FREQ_MHZ=` 仍是显式覆盖（空值），Makefile 的 `?= 50` 默认失效 → extract 行参数塌缩报 ValueError。

修法：yml 里裸 `make`。

**坑 3：归档下载截断。** job 完成后立刻下 zip 会拿到**边生成边流的截断包**（实测两次都断在 ~6.9KB）——加 `testzip()` 完整性校验 + curl --max-time 提到 180s + 重试窗口 3 分钟。

**Q：fmax 120.8 是真实性能吗？** 是 nextpnr 对 hx8k 这个布线结果的时序分析值（WASM 与 native 版一致）。真上板还受外部时序约束，但作为"RTL 改动是否劣化时序"的回归门禁完全成立。

**Q：120MHz 在裕量内为什么清单写"120 注错"？** 实测 fmax 裕量比清单预估大——注错点改成 200MHz（门禁语义不变：约束 > fmax 必红）。
