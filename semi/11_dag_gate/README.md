# 11 · ⛓️ 集成点②：MR 全流水线——needs DAG 与注错验证

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 11 · 阶段三「第一条芯片流水线」收官
> 终装 .gitlab-ci.yml：lint → unit → sim 串成 needs DAG，上游红下游跳过；README 挂 pipeline badge
> 验收在 `dag_gate.sh verify`：lint 级注错 / 仿真级注错 / 修复三段全过打 `[ok]`

## Background

P8-10 造了三个能独立跑的 job，但它们还是"三台并行的机器"——真正的流水线要表达**依赖**：lint 红了，unit/sim 根本不该跑（浪费算力还干扰视线）。

GitLab 的 `needs` 把 job 关系变成显式 DAG。本实验是集成点：终装 yml，然后用两类注错（lint 级 / 仿真级）实证 DAG 的分层拦截。

## What

心智模型一句话：**needs 是声明"我吃谁的输出"——上游没交付，下游连启动都不启动**。

| 注错 | 注入点 | 期望 DAG 表现 |
|:---|:---|:---|
| lint 级 | rtl/gcd.v 追加未驱动信号模块 | lint=failed，unit/sim=skipped |
| 仿真级 | sim/tb_main.cpp 期望值翻转 | lint=success，unit=success（cocotb 不受影响），sim=failed |
| 修复 | 从 main 还原两个文件 | 全绿 + badge 200 |

关键认知：**仿真级注错不影响 unit**——unit 用 tb_gcd.py（cocotb），sim 用 tb_main.cpp（C++ 驱动），两套独立验证程序验证同一个 SUT。验证程序分家，故障域也分家。验证方法：`./dag_gate.sh verify` 三段循环。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 上游失败下游必停 | needs（本实验）——省算力且失败原因唯一化 |
| 上游失败下游仍要跑（收集全部错误） | needs 加 `optional: true` 或并行 stage |
| 主线状态一眼可见 | README 挂 pipeline badge（本实验） |
| 想知道"下游为什么没跑" | job 状态是 skipped（needs 拦截）而非 canceled（手动取消）——语义可区分 |

## Quick Start

前置：项目 8-10 完成。

```bash
./dag_gate.sh up       # 推终装 yml（needs DAG）+ README badge
./dag_gate.sh verify   # 三段注错-修复循环（约 10 分钟）
./dag_gate.sh clean    # 删演示分支
```

`verify` 的真实输出（实测，全过）：

```
=====> [demo1] 注入 lint 级错误 → lint 红，unit/sim 因 needs 未执行
  [  =] pipeline #141 failed：lint=failed unit=skipped sim=skipped
  [ok]   lint 红、unit/sim 因 needs 被跳过（DAG 生效）
=====> [demo2] 注入仿真级错误 → lint 绿 unit 红 sim 不执行
  [  =] pipeline #142 failed：lint=success unit=success sim=failed
  [ok]   lint 绿、unit 绿（cocotb 不受影响）、sim 红且下游无（DAG 分层正确）
=====> [demo3] 修复 → 全绿 + badge 可访问
  [ok]   修复后全绿（pipeline #143 success）
  [ok]   pipeline badge 可访问（HTTP 200）

[ok] 项目 11 全部验收断言通过
```

## How It Works

### needs 拦截的 job 状态是 skipped

上游 failed 时，needs 声明的下游 job 直接 `skipped`——与手动取消的 `canceled`、排队中的 `created` 语义可区分。断言按实测写 `unit=(canceled|skipped)`（GitLab 版本间曾有状态名差异），但语义恒为"未执行"。

### 双验证程序的故障域隔离

同一 SUT（gcd.v）配两套验证程序（tb_gcd.py / tb_main.cpp）不是冗余：仿真级注错只翻 C++ 驱动的期望值，cocotb 线全绿——故障被精确定位到"sim 的验证程序"，而非"SUT 或流水线"。注错验证的本质是给流水线本身做单元测试。

### badge 的 302

`/badges/main/pipeline.svg` 对 HTTP（非 HTTPS）实例会 302 到渲染地址——`curl -L` 跟随后 200。徽章数据源是 main 的最新流水线，全绿即 "passing"。

## Pitfalls & Q&A

**Q：为什么 demo2 的 unit 没红？** 注错在 tb_main.cpp（sim 的驱动）。unit 的 cocotb 用 tb_gcd.py——这恰好证明了故障域隔离：若 RTL 真坏，两条验证线会同时红。

**Q：skipped 和 canceled 谁是"对"的？** 都是"未执行"。skipped=needs 拦截（本实验）；canceled=冗余流水线自动取消或手动取消。断言两者都认。

**Q：needs 会传递 artifact 吗？** 会——needs 的 job 的 artifacts 自动供下游下载（unit 的 results.xml、sim 的产物）。本实验三个 job 不交换文件，但 P15+ 的 release 流水线会用到。
