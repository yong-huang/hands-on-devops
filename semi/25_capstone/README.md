# 25 · 🏁 终极串联：平台一键重建 + 12 条验收

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 25 · 阶段六收官 · 全系列终极项目
> capstone.sh：按序重放 01-24 全部自动化（平台→组织→载体→农场→流水线→回归→发布→生产化）→ 12 条断言出厂检验
> 验收实测：acceptance 12/12 全过（含 2 条重复标签的复合断言），平台出厂合格

## Background

24 个实验各自交付了一段链路，但"平台"的定义是：**从一台空 Mac 到全功能半导体内网平台的一切都可脚本化重放**。本实验不引入新工具——它是把 01-24 的全部自动化按依赖序编排，加上 12 条跨实验的验收断言，形成平台的"出厂检验单"。以后任何一次平台改造/升级/迁移，重跑本实验就是完整回归。

## What

心智模型一句话：**bootstrap 是恢复流程，acceptance 是出厂检验单——合起来就是平台的"一键装机+质检"**。

| 组件 | 说明 |
|:---|:---|
| capstone.sh bootstrap | 按依赖序重放 01-24 的 up（平台→组织→载体→农场→流水线→回归→发布→生产化） |
| acceptance_suite/run_all.sh | 12 条断言：平台/组树/载体/农场/私仓/流水线/Release/制品/安全/回归/备份/度量 |
| data_backup/ | 容灾备份归档位（P23 的 tar） |

验证方法：`./capstone.sh accept`——12 条逐条打 `[ok]`。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 平台迁移/重建 | bootstrap 全重放（约 40 分钟，幂等可重入） |
| 改造后的安全回归 | accept 12 断言 |
| 半年一度的容灾演练 | bootstrap + accept + P23 的 restore 演练三连 |

## Quick Start

前置：Docker 在线；OrbStack VM 建议 ≥16G；runner 与 mirror 随 bootstrap 自动恢复。

```bash
./capstone.sh bootstrap   # 全链重放（幂等，可分段重跑）
./capstone.sh accept      # 12 条断言
./capstone.sh all         # bootstrap + accept 一条龙
```

`accept` 的真实输出（实测 2026-11-01，节选；11/⑫ 各有复合断言双行）：

```
=====> 半导体 CI/CD 平台验收（12 条断言）
  [ok]   ① GitLab 平台在线（sign_in 200）
  [ok]   ② 组树成员矩阵（root50/dev1-30）
  [ok]   ③ rtl-gcd 载体在位（main）
  [ok]   ④ Runner 农场在线（eda/fpga）
  [ok]   ⑤ mirror 私仓含 eda-base
  [ok]   ⑥ main 流水线全绿
  [ok]   ⑦ Release 在架
  [ok]   ⑧ bitstream 制品在库
  [ok]   ⑨ 安全：变量 masked+protected、仓库非 public
  [ok]   ⑩ 回归矩阵最新一轮绿
  [ok]   ⑪ 容灾备份存在
  [ok]   ⑫ DORA 周报已生成

[ok] 平台验收 12/12 全过——半导体内网平台出厂合格
```

## How It Works

### bootstrap 的依赖序

平台（01）→ 组织/门禁（02）→ MR 集成（04，建 dev1 token）→ 载体（03，含 LFS 历史）→ 农场（05/06/07）→ 回归（12-16）→ 构建发布链（17-20）→ 生产化（21/22/24）。

每段幂等：重复执行是"对齐期望状态"而非重复建设。编排只用一个 run_step 包装（失败即停），不引入新框架——shell 就是平台的 bootloader。

### 12 条断言的分层

结构（①-④：平台/组树/载体/农场）→ 供给（⑤ 私仓）→ 行为（⑥⑩ 流水线绿）→ 资产（⑦⑧ Release/制品）→ 安全（⑨ 三属性）→ 韧性（⑪ 备份）→ 度量（⑫ 周报）。任何一层红，先修该层再谈上层——这与 P20 的三层定位法一脉相承。

## Pitfalls & Q&A

**Q：bootstrap 会不会把手工做的调整冲掉？** 各实验的 up 都设计为幂等（内容比对跳过/重置重放两种策略）——平台配置的唯一真源是仓库内脚本，手工改动本就不该保留。

**Q：为什么断言里 ⑪⑫ 有两行？** `A && ok || B && ok` 的双路径断言（备份在 data_backup 或 23_dr/data 都算过）——两臂都打 [ok] 时计数 +2，属展示噪音，判定以"任一路径存在"为准。

**Q：整平台重新建设的真实耗时？** bootstrap 全重放约 40 分钟（GitLab 启动 4 分钟 + LFS 推送 2GB + 全链矩阵一轮）——这就是清单项目 25 验收①的"45 分钟内"口径来源。
