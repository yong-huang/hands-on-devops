# 20 · ⛓️ 集成点③：commit 到 Release 全链演练

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 20 · 阶段五「构建、制品与发布」收官
> 全链 DAG 总装：lint→unit→回归→(aggregate)→fpga→制品→release；全绿轮 + 注错轮的断点阻断实证
> 验收在 `full_chain.sh verify`：全绿轮一次过 / 回归红阻断 fpga，演练报告入 rtl-gcd 仓库，全过打 `[ok]`

## Background

P8-19 各自造了一段链路，但它们在 rtl-gcd 里是**逐段追加**的——从没整体验证过"DAG 是否真的按设计串联"。

集成点③做两件事：一次全绿跑通 lint→unit→回归→fpga→制品的完整链；再用注错轮证明断点真的会阻断（回归红 → fpga 不执行）。两轮的 job 状态与耗时都写进 rtl-gcd 仓库的 `docs/full_chain_report.md`——演练报告是配置正确性的存档证据。

## What

心智模型一句话：**stage 决定"排队的顺序"，needs 决定"谁开奖"——两者冲突时以 needs 的可达性为准**。

| 阶段链 | 内容 |
|:---|:---|
| lint → unit → sim | 代码质量与功能（P8-10） |
| regression（matrix+aggregate） | 种子回归与汇总（P12） |
| build：fpga → publish_artifact → release | 综合出 bitstream、签名入库、打 Release（P17-19） |

关键调整（本轮的实战发现）：fpga/publish/release 从各自的散装 stage 收拢进 **build 阶段**，且 fpga `needs: [aggregate]`——**回归没过就不值得综合**（EDA 语义：功能先行）。验证方法：`./full_chain.sh verify` 两轮演示。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 平台改造/升级前后 | 全链演练即回归测试（verify 两轮 ≈ 20 分钟） |
| "这个错会影响发布吗" | 看演练报告的注错轮：regression 红阻断 fpga，制品与 Release 天然不会带病出门 |
| 新 job 接入全链 | 先想 stage（排队顺序），再想 needs（开奖条件）——本轮的核心教训 |

## Quick Start

前置：项目 8-19 全部完成。

```bash
./full_chain.sh up       # 演练报告骨架推入 rtl-gcd
./full_chain.sh verify   # 全绿轮 + 注错轮（约 25 分钟）
./full_chain.sh status   # 最近流水线
```

`verify` 的真实输出（实测，全过）：

```
=====> [demo1] 全绿轮：lint→unit→回归→fpga→制品 全链一次绿
  [ok]   全绿轮流水线 success（#238）
=====> [demo2] 回归注错轮：regression 红 → fpga（needs）不执行
  [  =] 注错轮：... regression: [3]=failed ... fpga=skipped
  [ok]   regression 红、fpga 因 needs 未执行（断点阻断生效）

[ok] 项目 20 全部验收断言通过（演练报告见 rtl-gcd/docs/full_chain_report.md）
```

## How It Works

### needs 不可前向引用 stage（本轮最大实战发现）

`release`（stage: regression）写 `needs: [fpga]`（stage: build，更晚）——GitLab 直接报 `need fpga is not defined in current or prior stages`，**整条流水线 0 jobs failed**。

（ci/lint API 能查到这个错误。）修法：release 移入 build 阶段。规则记死：**stage 顺序是默认执行序，needs 只能在"当前或更早 stage"里找依赖**；跨 stage 的依赖必须把 job 挪到不晚于依赖者的 stage。

### 断点阻断 = needs 可达性，而非 stage 顺序

调整后回归红 → aggregate skipped → fpga（needs aggregate）skipped → publish/release 跟着断。

阻断是"可达性断链"：任何一条 needs 路径断了，其后所有 job 全 skipped——比 stage 顺序的"跑完才知道"强得多。

### 演练报告即存档

每轮的 job 状态与耗时追加进 rtl-gcd/docs/full_chain_report.md（脚本自动写）。

配置演进后重跑 verify 即可对比耗时漂移，报告就是平台性能的时序档案。

## Pitfalls & Q&A

**坑 1：needs 前向引用 stage → 整条流水线 0 jobs failed 且 yaml_errors=None。**

用 `POST /ci/lint` API 可以在 push 前本地校验（返回 "need fpga is not defined in current or prior stages"）——P11 的教训在这里升级成系统级排障手段。

**Q：为什么 fpga 放 build 阶段而不是 sim？** EDA 语义：回归（功能正确性）没过就不值得花算力综合。这也让"regression 红阻断一切下游"的验收成为 pipeline 结构的自然结果，而非脚本特判。

**Q：fpga job 里没有 install 步骤了？** yowasp 工具链由 cache（key=yowasp-ice40-v2，即 .yowasp-tools 目录）供给，P17 的 pip --target 装法首次 MISS 后全矩阵共享。
