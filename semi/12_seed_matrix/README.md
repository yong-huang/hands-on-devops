# 12 · 种子回归矩阵：16 路并行随机向量 + 聚合器

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 12 · 阶段四「回归农场」
> parallel:matrix 洒 16 个种子（每种子 32 组随机向量对拍 Python 参考模型），聚合器汇总 15/16 精确定位失败种子
> 验收：①基线 pass=16 fail=0（pipeline 146 aggregate artifact）②植入 seed7 必败 → 15/16 + failed_seeds=['7']

## Background

单条测试向量抓不住"偶现"的 RTL bug——真实验证靠**种子化随机回归**：随机激励 + 可复现种子，一台机器跑几万个种子，谁的种子红了就把种子号发给谁复现。这是验证团队的基本功，也是"重计算"型 CI 的核心形态：一次回归几十个种子并行跑满农场。

本实验把 rtl-gcd 的回归铺成 16 路矩阵：每种子 32 组随机向量对拍 Python 欧几里得参考模型（软件 gcd 天然是 RTL 的黄金模型），聚合器把 16 份子报告汇成一张 15/16 的失败地图。

## What

心智模型一句话：**matrix 洒种子，每个种子自带"指纹"，聚合器把指纹拼成失败地图**。

| 组件 | 说明 |
|:---|:---|
| regression job × 16 | `parallel:matrix` 注入 SEED=1..16；tb_random.py 用 random.Random(seed) 生成 32 组向量，对拍 math.gcd |
| 聚合器 | aggregate needs 全部子 job；收集 summary_seed_N.json → summary.json（passed/failed/failed_seeds） |
| 可复现性 | 同一种子永远生成同一向量序列——"seed=7 红"就是一张可直接回放的车票 |

## When to Use

| 场景 | 做法 |
|:---|:---|
| 偶现 bug 的捕获与复现 | 种子化随机 + 失败种子上报（本实验） |
| 回归时长爆炸 | matrix 并行摊到农场（runner 并发决定墙钟时间） |
| 部分种子失败时的决策 | 聚合器的 failed_seeds 列表：是否 block 合并由策略定 |
| 子任务失败后的汇总 | 注意 GitLab 语义：needs 的上游失败 → 聚合 job 被 skip（见 Pitfalls） |

## Quick Start

前置：项目 8-11 完成。

```bash
./seed_matrix.sh up      # 推 regression/aggregate stage + tb_random.py + runner/聚合器
./seed_matrix.sh verify  # 基线 → 注错（16 路矩阵 ≈ 15-20 分钟/轮）
./seed_matrix.sh status
```

实测证据（2026-10-31）：

```
基线 pipeline 146：20 jobs 全 success
aggregate artifact sim/summary.json：
  {"expected": 16, "collected": 16, "passed": 16, "failed": 0,
   "failed_seeds": [], "verdict": "pass"}

注错 pipeline 148：regression[7]=failed，其余 15 seeds success（aggregate 被 needs skip）
离线用同一聚合器汇总 16 份子报告：
  pass=15 fail=1 (collected 16/16, failed_seeds=['7'])
```

## How It Works

### 参考模型对拍：RTL 的"黄金模型"

随机向量的期望值来自 `math.gcd(a, b)`——软件实现即黄金模型。

RTL 与软件在 65535 全域随机对拍 32 组，比手写向量覆盖高两个数量级；而"期望怎么算"永远不需要写进 RTL。

### 聚合器的输入协议

每个子 job 产出 `sim/summary_seed_<SEED>.json`（文件名带种子避免 needs 下载时的路径互相覆盖）；聚合器 glob 收集、校验 collected==expected（16/16，少一个即 fail）——"子 job 静默丢失"也逃不掉。

## Pitfalls & Q&A

**坑 1：注入代码写进了"干净"模板。** 本实验的模板第一版把 seed7 注入直接写在 tb_random.py 里——基线永远 15/16。规则：模板必须干净，注入只发生在演示分支（对比文件 diff 可见）。

**坑 2：聚合 job 会被失败的上游 skip。** needs 的上游 failed → 依赖 job 直接 skipped，不会执行"汇总失败"逻辑。

失败时的聚合证据：用同一聚合器对子 artifact 离线跑（本实验验收②的做法）。要 CI 内自动汇总失败，需要 aggregate 改为 `when: on_failure` 的兄弟 job 或换报警通道。

**坑 3：16 路编译打满农场。** runner concurrent=2 时 16 个种子排队 15-20 分钟——真实农场会缓存编译模型（P10 的 cache 机制，key 不含 SEED 即可全矩阵共享编译产物）。

**Q：为什么每种子只 32 组向量？** 演示负载。真实验证每种子数万向量、种子数以千计——框架（matrix+聚合+可复现）不变，只改 N。

**Q：种子红一定是 RTL 的锅吗？** 不一定——参考模型、约束、激励生成都可能是错源。失败种子上报后人工复现定位，这正是"可复现性"的价值。
