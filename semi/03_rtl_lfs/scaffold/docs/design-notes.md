# gcd IP 设计约定

## 接口（W=16，可参数化）

| 信号 | 方向 | 宽 | 约定 |
|:---|:---|:---|:---|
| `clk / rst_n` | in | 1 | 低有效异步复位，同步释放由 tb 保证 |
| `in_valid` | in | 1 | 请求脉冲/电平皆可：与 `in_ready` 同拍即被接受 |
| `a_in / b_in` | in | 16 | 接受拍采样 |
| `in_ready` | out | 1 | 组合信号，IDLE 态为 1 |
| `out_valid` | out | 1 | 结果有效标志，保持到 `out_ready` |
| `result` | out | 16 | gcd(a,b)；gcd(0,0)=0 |
| `out_ready` | in | 1 | 交接拍，之后 DUT 回 IDLE |

## 目录结构

- `rtl/` —— 设计源码（只有 RTL，禁止放仿真产物）
- `tb/` —— cocotb testbench（Python）
- `sim/` —— 仿真入口（runner 脚本 + sim_build 产物目录，产物不进 git）
- `pdk/ gds/ waves/` —— 大文件目录：全部走 Git-LFS（见 `.gitattributes`）

## 大文件纪律

平台 pre-receive 拦 >50MB 直推；`*.lib / *.gds / *.vcd` 一律 `git lfs track`。
新工具链文件类型进仓库前先 track，别撞门禁。
