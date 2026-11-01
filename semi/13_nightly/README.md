# 13 · 夜间回归与失败治理：schedule + flaky 识别 + 失败种子重跑

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 13 · 阶段四「回归农场」
> nightly schedule（每天 02:00）+ flaky_hunter 扫真实流水线历史标 flaky + FAILED_SEEDS 触发只重跑失败种子
> 验收在 `nightly.sh verify`：schedule 在位 / seed7 被标 flaky / 重跑仅含 seed7 且通过，全过打 `[ok]`

## Background

回归农场的日常运营有两件事：**夜间跑大回归**（白天机器留给工程师）与**治理间歇性失败**。

间歇失败（flaky）是验证团队最贵的噪音——今天红的种子明天绿了，没人知道该信哪次。治理的第一步是"识别"：把每个种子在历史流水线里的红绿记录拉出来，时红时绿的就是 flaky 嫌疑犯。第二步是"止损"：失败种子定点重跑（而不是整个矩阵重来），省下 15/16 的算力。

## What

心智模型一句话：**schedule 是闹钟，flaky_hunter 是病历本，FAILED_SEEDS 是处方**。

| 组件 | 说明 |
|:---|:---|
| nightly schedule | 每天 02:00 在 main 上跑回归矩阵（`pipeline_schedules` API，cron 0 2 * * *） |
| flaky_hunter.py | 扫最近 N 条含回归矩阵的流水线，按种子统计红绿：healthy / flaky（时红时绿）/ broken（稳定红） |
| regression_rerun job | schedule 变量 `NIGHTLY_RERUN=true` + `FAILED_SEEDS=7` 触发，矩阵子 job 用 case 守卫只执行失败种子 |

验证方法：`./nightly.sh verify` 三条断言；`./nightly.sh status` 看 schedule。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 每日大回归 | schedule 定时（本实验）；配合农场低峰时段 |
| 种子时红时绿 | flaky_hunter 标记 → 隔离分析（真 RTL 问题 or 验证程序随机性） |
| 失败种子复跑确认 | FAILED_SEEDS 定点重跑（本实验）——大矩阵下省 15/16 算力 |
| 稳定红的种子 | broken 分类：直接开 bug 单，不浪费时间重跑 |

## Quick Start

前置：项目 12 完成（矩阵与真实红绿历史在位）。

```bash
./nightly.sh up       # 推 hunter + rerun job + 建 schedule（幂等）
./nightly.sh verify   # 三条断言（③会真跑一次 seed7 重跑，约 3 分钟）
./nightly.sh status   # schedule 清单
```

`verify` 的真实输出（实测，全过）：

```
=====> [verify] 验收② flaky_hunter 扫真实历史（146 全绿 / 148 seed7 红）
  seed  7: pass=9 fail=3 (115:success/.../108:failed/.../105:failed/104:failed)
  [warn] 扫描 12 条流水线：flaky=['7'] broken=[]
  [ok]   flaky_hunter：seed7 被标记 flaky（时红时绿）
=====> [verify] 验收③ FAILED_SEEDS=7 触发重跑 → 仅 seed7 真执行且通过
  [  =] rerun pipeline #151 success：regression jobs success=1
  [ok]   仅 seed7 一个 regression job 执行且通过（其余 skipped）

[ok] 项目 13 全部验收断言通过
```

## How It Works

### flaky 的判定是历史统计而非单次结果

单次红绿说明不了任何事：同一个种子在 12 条流水线里 pass=9 fail=3，才是 flaky 的定义。

hunter 用 GitLab API 把 `regression: [N]` 形态的 job 状态按名字聚合（名字里的种子号就是 key）。

**扫描窗口必须覆盖"含回归的全部 refs"**——真实历史分布在 MR 流水线上，只扫 main 会漏。

### 定点重跑的守卫模式

parallel:matrix 会为全部 16 个种子各建一个 job——无法在 YAML 层只选部分。

解法是 job 内守卫：`case ",$FAILED_SEEDS," in *",$SEED,"*)` 命中的才真正执行，其余秒退（skipped 语义无损）。失败的种子列表由 flaky_hunter 的报告喂数。

## Pitfalls & Q&A

**Q：为什么 hunter 第一版扫不到 seed7 的失败？** 两个原因：ref 过滤只看 main（真实历史在 MR 流水线）；窗口 N=5 太小（近期 5 条恰好全绿）。修法：全 refs + N=25——"看历史"的窗口要覆盖至少一次失败，这是采样问题不是代码问题。

**Q：重跑流水线怎么触发？** `POST /pipeline` 带 JSON body 变量（`variables[0][key]` 表单格式在 GitLab 19 会报 variables is invalid，必须 JSON）。变量进 rules 的 if 守卫与 job 内 case。

**Q：flaky 一定是坏的吗？** 不一定——flaky 的根源可能是 RTL 竞态、验证程序随机性、环境抖动三类。hunter 只负责"点名"，定性要靠失败种子的复现分析（种子可复现的价值在此）。