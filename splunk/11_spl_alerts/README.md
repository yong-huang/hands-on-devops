# 11 · 告警引擎：调度搜索 → webhook 送达

> 一条 cron */2 调度搜索挂上 webhook 告警动作，接收器记录载荷与到达时刻：3 次送达载荷含 search_name 与结果，相邻间隔 120s/120s 与 cron 表达式精确一致。读完你能带走：告警配置的最小应用包（app 包），和"告警真的送达"的机械化断言。

## Background

告警的验收陷阱是"规则配了就当会响"：saved search 写好、webhook 填上，UI 里绿色一勾——但调度器到底执行没有、动作到底发出去没有、间隔到底准不准，三件事都没被证明。告警恰恰是"平时不响、出事才响"的组件，第一次真实触发往往就是故障时刻，不能到那时才发现链路是断的。

之前（lab 07）已经证明"事件入库可以被搜索对账背书"；本实验把同样的对账思路套到告警链路——接收器把每次送达的载荷与时刻落盘，间隔断言直接量"调度器准不准时"。

## What

告警链路的四段结构与两条实测断言：

| 环节 | 载体 | 内容 |
|:---|:---|:---|
| 告警定义 | 应用包 `lab_alerts`（etc/apps/ 下自带配置的应用目录，内含 savedsearches.conf） | cron `*/2` + webhook 动作指向接收器 |
| 调度执行 | SavedSplunker（Splunk 内置的调度进程，按 cron 逐轮扫描到期搜索） | 搜索执行 → 触发条件满足 → 调用动作 |
| 动作送达 | webhook POST | `search_name` + `result` 载荷 → 宿主机 :28321 |
| 断言 | 接收器落盘的时间戳 | 3 次到达间隔 120s/120s（±10s） |

可以把调度告警想象成"闹钟"——但和闹钟不同，它的触发由调度器集中裁决：配置只是**注册**，真正响铃的是 SavedSplunker 每轮扫描；响不响、几点响，以调度器日志与接收器时刻差为准。

实测：3 次调度送达载荷均含 `search_name=hec_errorrate_alert` 与 `result={'err_events': '5250'}`，到达时刻 01:24:00 / 01:26:00 / 01:28:00——间隔精确 120 秒。

![dataflow](images/spl_alerts.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/11_spl_alerts/images/spl_alerts.html)
> （或本地打开 [`images/spl_alerts.html`](images/spl_alerts.html)）。

## When to Use

- **错误率告警**：状态码计数超阈值 → webhook 通知值班系统（本实验的触发条件简化为恒真，专测链路）
- **心跳监测**：结果为空即异常的反向告警（"最近 N 分钟无数据"）——同一套配置换个条件
- **何时不用**：一次性查询不需要告警；接收端不支持 webhook 时选 email/pagerduty 等其他动作（配置方式相同）

| 送达方式 | 差异 | 什么时候选它 |
|:---|:---|:---|
| webhook（本实验） | JSON 载荷、对接自由 | 自建值班/自动化系统 |
| email | 零开发、格式固定 | 人工值守 |
| summary index | 结果入库、可再检索 | 告警结果需二次分析 |

## Quick Start

前置：lab 01 实例 + lab 02 教程数据（告警搜索以它为数据源）。

```bash
cd splunk/11_spl_alerts
./spl_alerts.sh all   # up → wait → clean（含 3 次 cron 送达等待，约 8-10 分钟）
```

`wait` 的断言真实输出（节选）——3 次送达、载荷完整、间隔精确：

```
=====> [wait] 等 3 次 cron 调度送达（*/2）→ 载荷与间隔断言
        [ok] 已累计 3 次调度送达
        ✅ 断言 A：调度送达载荷含 search_name 与结果（result={'err_events': '5250'}）
        2026-11-17 01:24:00  search_name=hec_errorrate_alert
        2026-11-17 01:26:00  search_name=hec_errorrate_alert
        2026-11-17 01:28:00  search_name=hec_errorrate_alert
        相邻间隔: 120s, 120s（cron */2 = 120s，容差 ±10s）
        ✅ 断言 B：3 次调度间隔与 cron 表达式一致
```

诚实预期：`all` 约 8-10 分钟——大头是等 3 次 cron 送达（每 2 分钟一次，首送达可能落在下一个偶分）。教程数据的事件时间固定在 11 月上旬，与"现在"无关，因此触发条件刻意设为恒真（count>0），让 cron 本身成为触发源。`clean` 删应用包与接收器，归零。

## How It Works

**调度搜索必须住在应用包里**。savedsearches.conf 放 `etc/system/local/` 时，SavedSplunker 拒绝执行（实测日志：`cannot execute scheduled searches ... need an app context`）。

解法是打包成最小应用：`etc/apps/lab_alerts/` 下 default/app.conf（启用声明）+ local/savedsearches.conf（告警定义）。

**动作只由调度器触发**。手动 dispatch（Run once 的 REST 等价物）只执行搜索——实测任务正常完成，接收器零载荷、不触发动作。

只有调度器路径会走 `sendmodalert`（Splunk 内部触发告警动作的命令；实测日志：`Invoking modular alert action=webhook`）。因此验收就是等调度送达，而不是手动触发。

**间隔断言的取材**。接收器把每次送达的 `arrived_epoch` 落盘；断言取最近 3 次送达的时刻差（120s/120s，容差 ±10s）——直接度量调度器的准点率，绕开对 Splunk 内部时钟的一切假设。

## Pitfalls & Q&A

- **system/local 的调度搜索不执行**：SavedSplunker 需要 app 上下文。解法：打包成最小应用（default/app.conf + local/savedsearches.conf）
- **应用内声明同名动作会遮蔽内置定义**：本实验最初在应用包写了 `[webhook]` 段，Splunk 转而在该应用 bin/ 下找动作脚本（不存在）→ `Alert action script for action "webhook" not found`，送达静默失败。解法：删掉声明，直接用出厂内置 webhook
- **REST 命名空间要用显式 app**：`/services/saved/searches/<名>` 落在默认应用上下文，看不到 lab_alerts 里的告警。解法：`/servicesNS/nobody/lab_alerts/saved/searches/<名>`
- **接收器残留实例造成"送达黑洞"**：旧实例占着端口、写进已删除的目录，新送达全部蒸发。解法：起接收器前 `pkill -f webhook_receiver`
- **脚本用 `ls tmp/webhook_*.json` 在无匹配时静默退出**：无匹配时 ls 退出码 2，`pipefail` 下 set -e 直接中止脚本。解法：改用 `find tmp -name 'webhook_*.json'`

**Q1：为什么不保留"手动 Run once 触发"的断言？** 实测 dispatch 不触发动作——Run once 在 UI 里的语义是"立即执行一次搜索"，动作仍由调度链路裁决。保留会误导读者；真实可复跑的断言只有调度送达，验收随之校准。

**Q2：触发条件为什么是恒真？** 教程数据事件时间固定在 2026-11 上旬，与真实时钟脱节——任何带时间窗的真实条件都可能"永不触发"。本实验测的是**链路**（调度→动作→送达→间隔），恒真条件让 cron 成为唯一的触发源，链路每 2 分钟被完整验证一次。

**Q3：`alert.track = 0` 会关掉动作吗？** 不会。track 只控制"触发历史是否可见"（Alerts 页面），动作照发；suppress（抑制窗口）才影响重复触发。实测 track=0 下三次送达全部正常。
