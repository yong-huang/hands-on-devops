# 04 · 统计管道：业务三问 × 双口径对照

> 用三问（每小时趋势 / Top 10 来源 / 404 占比）练统计命令族，每问两种写法对照；再用一份零共享代码的 Python 实现独立复算，断言两口径误差 ≤1%——SPL"跑出数"和"算得对"从此有证据。读完你能带走：三条可复用的统计查询模板、一套同题写法对照，和一个双口径验收方法。

## Background

统计查询有个隐蔽的坑：查询跑通、数字出来，不代表算得对——分桶（把时间轴切成等宽区间分别统计）边界错一格、字段解析差一行，趋势图照样画得出来。

之前验证 SPL（Splunk 的检索语言，从 `search` 命令开始、以管道连接处理命令）只有"看输出像不像预期"一途，没有独立参照。

反过来，每个统计问题在 Splunk 里都至少有两种写法（`timechart` 与 `bin`+`stats`、`top` 与 `sort`+`stats`），哪种更对？都对——但口说无凭。本实验拿官方教程数据的三问当题面：每种写法都跑、再用纯 Python 逐行解析同一份原始日志独立复算，两口径对齐才算数。

## What

三个业务问题与结论（数据：lab 02 入库的 access_combined 日志，跨 2026-11-07 至 11-14 共 7 天，39,532 条）：

| 业务问题 | 主写法 | 结论（实测） |
|:---|:---|:---|
| 每小时访问量趋势？ | `timechart span=12h count` | 15 个桶全非空，12h 桶计数 1220-3006 |
| Top 10 访问来源？ | `top limit=10 clientip` | 头名 87.194.216.51，1036 次（2.62%） |
| 404 占比随时间变化？ | `count(eval(status=404))` | 总体 1.7454%，逐日 1.56%-1.93% |

可以把统计管道类比成 SQL 的 `GROUP BY`——按时间或字段分组、组内聚合。但和 SQL 不同，SPL 的"表"来自管道上游的事件流，分组键可以直接是 `_time` 的分桶（`bin`/`timechart`），且聚合函数里还能嵌条件（`count(eval(status=404))`）。

![dataflow](images/spl_stats.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/04_spl_stats/images/spl_stats.html)
> （或本地打开 [`images/spl_stats.html`](images/spl_stats.html)）。

## When to Use

- **日常运维问答**：流量趋势、来源排行、错误占比是三类最高频的统计形态，模板换字段即用
- **验证复杂 SPL**：写完一条没把握的聚合查询，用独立实现对照一次，比肉眼靠谱
- **何时不用**：精确到秒的逐事件审计不走聚合；超大数据量的高频统计该用 `tstats`（lab 02 已演示）或预聚合 summary index（把统计结果预先算好存进专用索引的加速手段，后续实验展开）

| 验证方式 | 差异 | 什么时候选它 |
|:---|:---|:---|
| 肉眼看输出 | 快但无证据 | 探索性查询 |
| 双口径对照（本实验） | 有硬断言 | 关键报表/上线前 |
| 单元测试式断言 | 强但维护重 | 固化后的核心报表 |

## Quick Start

前置：lab 01 实例与 lab 02 教程数据（数据不足时脚本自动补灌）。

```bash
cd splunk/04_spl_stats
./spl_stats.sh all   # up → queries → crosscheck → clean
```

`queries` 的三问输出（节选）——每问两种写法数字完全一致：

```
        ── Q2a top（自带 percent 列）
        clientip=87.194.216.51  count=1036  percent=2.620662  _tc=39532
        ── Q3a stats 条件聚合算占比
        total=39532  nf=690  pct=1.7454
        ── Q3b eval+sum 同题对照
        nf=690  total=39532  pct=1.7454
```

（nf = 404 事件数；pct = 404 占总体百分比。）

`crosscheck` 的双口径结论（节选）——Python 逐行解析 39,532 行、0 行跳过，四项对比全绿：

```
Python 端：解析 39532 行（跳过 0 行非标准行）
  Q1 每小时趋势：15 桶全对比 ✅
  Q2 Top10 来源：IP 集合一致，计数对比 ✅
  Q3 404 占比：py 1.7454% vs spl 1.7454% （总量 py 39532 / spl 39532）✅
  Q3c 逐日 404 占比：8 天 ✅
```

诚实预期：`all` 全程约 1-2 分钟（数据已在库时）；Python 端解析 7 天日志约数秒。`clean` 只清 tmp，教程数据归 lab 02 管。

## How It Works

**同题两写法为什么等价**。`timechart span=12h count` 在 Splunk 里就是"按 `_time` 做 12h 分桶再计数"的语法糖——与 `bin _time span=12h | stats count by _time` 的语义重合，实测 15 桶逐值一致。

`top` 是"分组计数 + 降序 + 附加 percent 列"的封装，`sort -count | head 10` 得到同样的 IP 与计数（实测表列完全相同），差异只在 percent 装饰列。

**双口径对照的设计**。Python 端（`crosscheck.py`）与 SPL 端零共享代码：正则逐行解析原始文件（`^clientip - - [ts] "req" status bytes`）。

时间戳按 UTC 对齐 Splunk 容器的解析口径，用同样的 12h/1d 网格分桶。"跳过 0 行"本身就是解析器的体检——有一行不匹配都会让总数对不上。

**条件聚合**。`count(eval(status=404))` 在 count 内嵌一个条件表达式：给每条事件算 1/0 再计数，一行 SPL 同时产出 `total` 与 `nf`。

等价写法 `eval is404=if(...) | stats sum(is404)` 把两步拆开——实测占比一致（1.7454%）。

## Pitfalls & Q&A

- **按"24 小时桶"写断言直接失败**：最初设计假设数据只覆盖一天，实测教程数据跨 7 天整。解法：断言跟着实测校准（`timechart span=12h` → 15 桶全非空），先量数据跨度再定断言
- **Python 子进程拿不到密码**：`source .env` 只设 shell 变量、不导出，子进程环境里没有。解法：`set -a; source .env; set +a`
- **时区口径不一致则分桶全错**：Splunk 容器按 UTC 解析 `[07/Nov/2026:18:22:16]`；Python 端 strptime 后必须同样挂 UTC（`replace(tzinfo=utc)`），否则桶错位、Q1 全线超差
- **`top` 的 percent 合计不是 100**：percent 是每项占**总量**的份额，Top10 合计约 11.9%——它回答"头部集中度"，不是"分布归一化"

**Q1：两写法什么时候不等价？** `top` 默认按 count 降序并截断，`sort -count | head 10` 需要自己写截断；`timechart` 会为空桶补 0、`bin`+`stats` 不产出空组——趋势图用 timechart，精确分组统计用 bin+stats。

**Q2：Python 端为什么能 0 行跳过？** 教程数据是官方生成的标准 access_combined 格式，正则全覆盖。真实日志常有截断行/编码噪声——那时"跳过行数"就是必须检查的健康指标，跳过多说明解析器覆盖不全，两口径对照也随之失真。

**Q3：容差为什么定 1% 而不是 0？** 理论上同一份、同口径的数据应该精确一致（本实验实测就是 0 偏差）。留 1% 是给"数据在入库与解析之间发生轮转/截断"的现实场景留余量——断言太紧会在无关的运维噪声上误报。
