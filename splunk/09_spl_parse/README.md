# 09 · 自定义 sourcetype：多行栈与 CSV 结构化双轨

> 两种最常见"非标准"数据——多行异常栈与结构化 CSV——各配一份 props.conf：多行按行首时间戳切事件（488 行切回 100 个事件不丢不并），CSV 走 INDEXED_EXTRACTIONS 索引时字段。四条断言全绿后归零。读完你能带走：两种解析轨道的配置模板，和"切分正确性"的对账方法。

## Background

异常栈是日志解析的经典难题：一个异常占多行（首行 + 若干缩进栈帧），按行切事件就把一个异常撕成碎片，检索与统计全部失真。结构化 CSV 则相反——它不需要"切"，需要"按表头拆列"，拆完还要能按时间列当 _time。

之前（lab 05）用 REPORT 做过单行 access 日志的搜索时字段提取；本实验推进两个新维度：**多行合并**（事件边界不在行边界上）与**索引时提取**（INDEXED_EXTRACTIONS，字段入库即落盘，与搜索时提取的成本模型相反）。两条轨道各配一份 props.conf，用四条断言验证。

## What

两种 sourcetype、两种解析语义：

| sourcetype | 数据形态 | 关键配置 | 字段时机 |
|:---|:---|:---|:---|
| splk_stack | 多行异常栈（488 行 → 100 事件） | `BREAK_ONLY_BEFORE` + `SHOULD_LINEMERGE` | 搜索时（REPORT） |
| splk_csv_lab | CSV（表头 + 50 行） | `INDEXED_EXTRACTIONS = csv` | 索引时（入库即有） |

可以把多行解析想象成"按段落读文件"——行是字符、事件是段落，`BREAK_ONLY_BEFORE` 就是段落起始的标记。但和段落不同，Splunk 的切分发生在**管道流式阶段**：规则错一格，两个事件并成一个或一个撕成两个，计数立刻露馅——这就是断言 A 用"事件数对账"做证据的原因。

![dataflow](images/spl_parse.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/09_spl_parse/images/spl_parse.html)
> （或本地打开 [`images/spl_parse.html`](images/spl_parse.html)）。

## When to Use

- **异常栈/堆栈型日志**：Java/Python traceback、k8s（Kubernetes，容器编排平台）事件块——凡是"首行 + 续行"结构都需要多行合并
- **批量结构化文件**：CSV/TSV 导出、供应商对账单——INDEXED_EXTRACTIONS 一次配好、入库即字段齐全
- **何时不用**：行式日志（access/nginx）用 lab 05 的 REPORT 更轻；字段规则还要频繁试错的探索期，先 rex 再固化

| 数据形态 | 解析方式 | 字段时机 |
|:---|:---|:---|
| 单行规则格式 | REPORT（lab 05） | 搜索时 |
| 多行事件（本实验 A 轨） | BREAK_ONLY_BEFORE + REPORT | 搜索时 |
| 结构化文件（本实验 B 轨） | INDEXED_EXTRACTIONS | 索引时 |

## Quick Start

前置：lab 01 实例；无其他依赖（测试数据由 gen_testdata.py 现场生成）。

```bash
cd splunk/09_spl_parse
./spl_parse.sh all   # up → deploy → ingest → verify → clean
```

`deploy` 产生数据与 `verify` 四条断言的真实输出（节选）：

```
{"events": 100, "base_ts": 1794845673.03, "last_ts": 1794845772.03, "csv_rows": 50}
        [ok] 100 条栈事件全部可见（约 5s）
        ✅ 断言 A：多行栈切分 100 事件（不丢不并）
        ✅ 断言 B：_time 与产生器时间范围一致（栈与 CSV 双源 ±3s）
        ✅ 断言 C：REPORT 字段 level/svc null=0（100 事件全覆盖）
        ✅ 断言 D：CSV 50 行对账（INDEXED_EXTRACTIONS 字段可查，user 5 种）
```

诚实预期：`all` 全程约 3-4 分钟（含 deploy 配置生效与 clean 清理各一次、每次约 60 秒的容器重启；数据量小、入库秒级）。`clean` 删 parse_demo 索引与 props/transforms 并重启归零。

## How It Works

**多行切分的边界规则**。`BREAK_ONLY_BEFORE = ^\d{4}-...` 告诉 Splunk：每当一行以时间戳开头，就开启一个新事件，后续非时间戳行全部并入——488 行按此规则归并成 100 个事件。

事件数对账（断言 A）就是切分正确性的证据。`SHOULD_LINEMERGE = true` 是启用合并的总开关；`MAX_EVENTS = 256` 是单事件行数上限（防止规则失效时吞掉整个文件）。

**CSV 的索引时字段**。`INDEXED_EXTRACTIONS = csv` 让 Splunk 在入库阶段按表头拆列：ts/user/action/region/latency_ms 直接成为可检索字段（断言 D 的 `dc(user)` 不经任何提取即可用）。

时间戳来自 `TIMESTAMP_FIELDS = ts`——断言 B 对照产生器范围验证了这一点。

**两轨的时机差异**。A 轨（REPORT）是搜索时提取：改规则立即对旧事件生效、不入盘；B 轨（INDEXED_EXTRACTIONS）是索引时：字段值写进 tsidx、检索快，但改规则后必须重灌数据。选型口诀：规则稳定且追求检索性能选索引时，规则还在演化选搜索时。

## Pitfalls & Q&A

- **多行事件计数超 100**：BREAK_ONLY_BEFORE 忘写 `^` 或正则被日志里的次级时间戳（栈帧里的日期）误触发。解法：锚定行首 + `MAX_TIMESTAMP_LOOKAHEAD` 收紧到 19（只看行首 19 字符找时间）
- **CSV 字段查不到**：INDEXED_EXTRACTIONS 只对**入库时**生效——先入库后配规则的事件不会有字段。解法：先部署 props 再入库（本实验 deploy 在 ingest 之前）
- **`_time` 取了文件修改时间**：时间字段没配对时 Splunk 回落到文件 mtime。解法：`TIMESTAMP_FIELDS` + `TIME_FORMAT` 显式指定（断言 B 抓的就是这个）
- **验证脚本读不到 prod.json**：产生器输出只打 stdout 不落盘，verify 阶段就断了。解法：产生器把摘要写成 tmp/prod.json（实测踩过）

**Q1：MAX_EVENTS 上限到了会怎样？** 超过 256 行仍未遇到新边界，事件被强制截断、剩余行另起事件——计数会超 100。

它是"规则失效时的保险丝"，不是精确工具；长栈日志应调大或改用 LINE_BREAKER（Splunk 直接定义行边界的底层正则属性，BREAK_ONLY_BEFORE 这组高层开关最终也由它落实）。

**Q2：断言 B 为什么两个 sourcetype 都对照？** 多行事件的 `_time` 取**首行**时间戳（props 的 `TIME_PREFIX = ^` 让 Splunk 到行首找时间戳）。

CSV 的 `_time` 则取 ts 列——两条轨道的时间解析路径不同，各对照一次才能证明各自的 props 时间配置都对。

**Q3：INDEXED_EXTRACTIONS 和 lab 05 的 REPORT 能同时用吗？** 能，甚至常配合：入库时拆出高频字段（索引时），低频长尾字段留给搜索时 REPORT。同时注意同名冲突——索引时字段优先，搜索时提取会被其遮蔽。
