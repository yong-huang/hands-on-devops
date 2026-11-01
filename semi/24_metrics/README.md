# 24 · 流水线度量：DORA 四指标与瓶颈定位

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 24 · 阶段六「生产化」
> dora_report.py：成功率/CFR/MTTR/部署频率 + 最慢 stage 定位；已知数据集单测锁死数学
> 验收在 `metrics.sh verify`：3红7绿单测 / 真实数据集 + 瓶颈一致性交叉验证，全过打 `[ok]`

## Background

流水线跑了几十轮（P8-20 的全部演示），但没有度量就只有"感觉"：成功率多少？哪类错最频繁？瓶颈在哪个 stage？DORA 四指标（部署频率/前置时间/MTTR/变更失败率）是 DevOps 效能的通用语言，GitLab 的 API 把每个指标都变成了可拉取的数据——本实验把它们算出来并锁死数学。

## What

心智模型一句话：**API 是原料，compute 是配方，周报 JSON 是成品——配方必须过单测**。

| 指标 | 口径（本平台映射） |
|:---|:---|
| 成功率 / CFR | main 流水线 success/failed 占比 |
| 部署频率 DF | releases 数 / 窗口天数 |
| MTTR | failed → 下一条同 ref success 的间隔均值 |
| 前置时间（代理） | 流水线 duration 均值（无环境部署时的近似口径） |
| 瓶颈 stage | 最近 20 条流水线各 stage 耗时聚合 top1 |

验证方法：`./metrics.sh verify`——单测锁数学，交叉验证锁口径。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 平台健康周报 | dora_report.py 输出 JSON → 邮件/看板 |
| 改造前后对比 | 同脚本跑两窗（改造前后各 30 天），指标 diff 即收益证明 |
| 容量规划 | worst_stage 的耗时占比 → 知道该给哪个 stage 加资源 |
| 安全回归 | verify 的双验证（单测+交叉）本身是度量系统的回归测试 |

## Quick Start

前置：平台在线（历史数据 ≥10 条流水线）；pip python-gitlab（已装）。

```bash
./metrics.sh up       # 推 dora_report.py 到 rtl-gcd（幂等）
./metrics.sh verify   # 单测 + 真实数据集 + 交叉验证
./metrics.sh status   # 周报 JSON
```

`verify` 的真实输出（实测，全过）：

```
=====> [verify1] 已知数据集单测（3 红 7 绿：成功率 70%、CFR 30%、MTTR 60min）
  [ok]   单测全过（计数/CFR/MTTR 数学正确）
=====> [verify2] 真实数据集：周报 JSON + 瓶颈 stage
  [ok]   瓶颈 stage 与独立聚合一致

[ok] 项目 24 全部验收断言通过
```

## How It Works

### compute 与 collect 分离（可测试性设计）

指标数学抽成纯函数 `compute_from_pipelines(pipelines, releases, days)`——单测直接喂 10 个假 pipeline 对象断言输出，不需要 GitLab。

collect 只负责"从 API 拉数并排序"。这不是风格洁癖：DORA 的公式错了会让所有改进决策失据，必须用已知数据集锁死。

### MTTR 的口径：failed → 下一条 success

失败后必须有恢复才算 MTTR 有意义。算法顺序扫描：记下最近一次 failed，遇下一条 success 求差并清空——连续失败只算到第一次恢复。窗口截断（开头就是 success）自然不计。

### 瓶颈定位：同窗口聚合

各 stage 耗时聚合取 top1。交叉验证用独立实现（shell/python 两路）对拍——度量系统的 bug 会让优化方向南辕北辙，双路对拍是度量可信的底线。

## Pitfalls & Q&A

**坑 1：list() 懒加载对象缺 duration。** python-gitlab 的 pipelines.list() 返回简化对象——逐条 p.pipelines.get(id) 拿全量字段后再算（代价是 API 调用×N，窗口控制在 20 条）。

**坑 2：arg 顺序（脚本被三处调用）。** dora_report.py 的 main 收 token 文件路径/project/out——metrics.sh 与测试各按自己的上下文传参，改签名时两处调用点都要对齐（本轮实测踩过：URL 被当 token 文件 open）。

**Q：窗口怎么选？** 报告扫最近 20 条全 ref 流水线（含 MR）；交叉验证必须与报告**同窗**——实测窗口不一致会导致瓶颈"不一致"的假失败。

**Q：MTTR 60min 是好是坏？** 没有绝对好坏——它是基线。改平台（加缓存/加 runner）后同脚本重跑，指标变化才说明问题。
