# 03 · SPL 首搜：把速查卡变成可执行的验收

> 把 14 条 SPL 写进一张速查卡，再用脚本从卡里提取、经 REST 逐条执行并断言 0 报错——"学了"和"验过"绑在同一条链上。读完你能带走：一张覆盖时间/字段/整形/eval/where 的速查卡，和一套"卡片即契约"的自验收模式。

## Background

查日志最原始的做法是在界面里点选报表、逐条翻结果——会操作但不会检索语言，换个问题就得重新点一遍。Splunk 的核心能力是 SPL（Splunk 的检索语言，从 `search` 命令开始、以管道连接处理命令），命令多、管道段自由组合，光学不练记不住。

练了怎么验证？笔记抄一遍"大概会了"没有任何证据支撑。本实验的做法：把要掌握的 SPL 写成速查卡（`spl_cheatsheet.md`），脚本从卡里提取全部语句、经 REST 逐条真实执行、断言 0 报错——卡片就是验收对象，学过的每一条都被机器确认过。

## What

SPL 是一条事件流管道：`search` 段按索引（Splunk 存放已入库数据的仓库，lab 02 建的 `tutorial` 就是一个）与时间筛出事件流，后续管道命令逐段变换（选列、算新字段、过滤、聚合），末段决定输出。

可以把管道类比成 shell 的 `grep | awk | sort`——但和 shell 不同，SPL 的每一段作用在"事件表"（结构化行）上而不是字节流上，且字段是解析出来的列。

两个最容易混的命令分工：

| 命令 | 作用 | 例子 |
|:---|:---|:---|
| `eval` | 造新字段（全量事件都带上） | `\| eval bytes_kb=round(bytes/1024,1)` |
| `where` | 筛行（按字段表达式丢弃事件） | `\| where bytes > 4000` |

时间范围是第一等公民：`earliest`/`latest` 写在 search 段，进入管道前就把数据量切小——放在管道后段过滤就浪费算力了。

![workflow](images/spl_run.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/03_spl_basics/images/spl_run.html)
> （或本地打开 [`images/spl_run.html`](images/spl_run.html)）。

## When to Use

- **日常检索与报表初稿**：速查卡上的组合（时间窗 + 字段整形 + 聚合）覆盖八成日常问题
- **给后续实验打地基**：字段工程、仪表盘、告警的 SPL 都以本卡为母本扩展
- **何时不用**：超大索引上的精确统计该走 `tstats`（只读索引元数据，lab 02 已演示）；定时产出的报表该用 saved search 而不是每次手跑

| 方式 | 差异 | 什么时候选它 |
|:---|:---|:---|
| UI 点选 | 无语言积累，换问题就重来 | 一次性看一眼 |
| 速查卡 SPL（本实验） | 可积累、可对照 | 日常检索主力 |
| saved search | 调度与复用 | 固定周期报表（告警实验） |

## Quick Start

前置：lab 01 实例与密码（`../01_splunk_deploy/.env`）；tutorial 数据不足时脚本自动复用 lab 02 补灌。

```bash
cd splunk/03_spl_basics
./spl_run.sh all   # up → run → clean
```

`run` 的真实输出（节选）——先过结构断言（条数与组合数），再逐条执行：

```
=====> [run] 从速查卡提取 SPL → REST 逐条执行 → 断言
        ✅ 提取 14 条 SPL（≥12）
        ✅ eval+where 组合 2 条（≥2）
        [10/14] ✅ 10. eval 算术（bytes 换算 KB） —— 5 行
        [11/14] ✅ 11. eval 条件分类（if 三参写法） —— 2 行
        [13/14] ✅ 13. eval + where 组合①（算出衍生量再过滤） —— 0 行
        ✅ 全部 14/14 条 SPL 执行 0 报错
```

诚实预期：首跑若 tutorial 数据为空，会自动触发 lab 02 的补灌（约 6-8 分钟）；后续重跑 `all` 免去补灌，14 条逐条往返实测约 4 秒。第 13 条返回 0 行是预期行为（见 Pitfalls），0 行不算报错。

## How It Works

**卡片即契约**。提取逻辑只认两样东西：`### ` 标题行给条目命名，紧随的 ```` ```spl ```` 围栏给语句本体；`#` 注释行剥掉、多行拼一行。卡片怎么改，验收就怎么跑——不存在"文档一套、实际一套"。

**结构断言先于执行**。先数条数（≥12）与 eval+where 组合数（≥2），不达标直接失败——这是清单验收标准的程序化表达。执行关在后面：每条 SPL 以 oneshot 模式（同步执行、结果随响应返回、任务不落盘）提交到 `/services/search/jobs`。

**报错判定看 messages**。REST 响应里 `results` 是数据、`messages` 是诊断。判定规则：出现 `type=ERROR` 或 `FATAL` 即 FAIL；`results` 为空不算错（过滤类语句合法地筛空）。

**验收数据是共享的**。`up` 步骤检查 `index=tutorial` 的事件量，不足 1000 就调用 lab 02 的 `download`/`ingest` 补灌——实验之间靠产物衔接，而不是各造各的数据。

## Pitfalls & Q&A

- **`set -o pipefail` 下用 grep 过滤命令输出会静默中止脚本**：过滤后无匹配时 grep 退出码 1，整个管道被判定失败。解法：透传输出（本脚本补灌段只用 sed 缩进），失败靠 pipefail 捕获被调脚本自身的退出码
- **`round()` 先取整再 `where` 过滤会失真**：速查卡第 13 条 `eval size_mb=round(bytes/1024/1024,2)` 后 `where size_mb > 0`，4KB 的事件被取整成 0.00，全部被筛掉——返回 0 行。解法：过滤用原始量纲（`bytes > 4000`），展示才取整
- **0 行 ≠ 报错**：`dedup | stats count` 这类聚合返回 1 行，`table | head` 返回 N 行，过滤筛空返回 0 行——都是合法结果；只有 `messages` 里的 ERROR/FATAL 才 FAIL

**Q1：eval 能代替 where 吗？** 不能各干各的：eval 只造字段不筛行（全量事件都带上新列），where 只筛行不造列（它引用已有字段做判断，自己不产生新列）。组合用法是"eval 造衍生量 → where 按量筛"，速查卡 13/14 条就是这个模式。

**Q2：为什么 `where` 不写在 search 段？** `bytes > 4000` 这类比较放进 search 段（`index=tutorial bytes>4000`）也合法，且能利用索引裁剪、更快。

`where` 的价值在管道中段引用 eval 刚造出来的字段——原始字段在 search 段筛，衍生字段在管道筛。

**Q3：oneshot 和普通搜索作业的区别？** oneshot 同步跑完、结果直接在 HTTP 响应里返回，任务历史几分钟后过期；普通作业是异步的（拿到 sid——搜索作业 ID——后轮询），适合大数据量与看板。验收脚本要的是"提交即得结论"，oneshot 正合适。
