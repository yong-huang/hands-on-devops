# 07 · HEC 实时接入：进程直推 JSON 事件

> 绕开文件与转发器，进程用 HTTP 直接把 JSON 事件推进 Splunk：单事件 ack 回执、1 万条批量对账（发送=入库，差额 0）、_time 取事件时间实证。读完你能带走：HEC 协议的完整请求形态（token/channel/ackId）、一个"code=0 却没入库"的静默坑、一个"入库数对不上账"的计数坑，和一个可直接复用的 Python 批量产生器。

## Background

此前实验的数据都"先落盘再入库"：教程数据靠 oneshot 灌文件，真实日志靠转发器读文件。微服务、容器、定时脚本产生的数据没有文件——它们是进程内存里刚生成的 JSON，等写盘再采集既绕路又丢时效。

HEC（HTTP Event Collector，Splunk 的 HTTP 事件入库通道）就是为这类场景准备的：进程 POST 一段 JSON 到 8088 端口，事件即入索引。

但"HTTP 收下"不等于"索引收下"——本实验用三组断言把 ack 语义、数量对账、时间戳归属全部钉死，中间实测出两个坑：一个"响应成功却丢数据"（索引不存在时静默丢弃），一个"入库数对不上账"（ack 演示事件混入对账）。

## What

HEC 请求的最小形态与三要素：

| 要素 | 值（本实验） | 作用 |
|:---|:---|:---|
| 端点 | `POST /services/collector/event`（批量 = body 多行 JSON，每行一个事件对象） | 通道 |
| 鉴权 | `Authorization: Splunk <token>`（inputs.conf 里定义的 32 位 hex） | 代替账密 |
| 路由 | 事件对象里的 `"index": "hec_demo"`、`"sourcetype": "splk_hec_json"`、`"time": <epoch>` | 落哪个索引/怎么解析/_time 取值 |

可以把 HEC 想象成"事件的 HTTP 收发室"——但和普通 API 不同，它收下（code=0）只代表进了收发室，事件还要走解析、路由、写盘的完整管道；管道上任何一环出问题（比如目标索引不存在）都是**静默丢弃**，这也是本实验先建索引再发事件的原因。

三组断言的实测结论：ack 回执异步翻转（POST 后立即查询是 false，约 5s 后翻 true）；1 万条 0.13s 发完、入库对账差额 0；_time（Splunk 给每条事件标注的时间戳，按时间范围检索就靠它）与事件内 time 字段逐秒一致、与接收时刻相差 5400s（产生器故意预置的滞后）。

![dataflow](images/spl_hec.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/07_spl_hec/images/spl_hec.html)
> （或本地打开 [`images/spl_hec.html`](images/spl_hec.html)）。

## When to Use

- **容器/微服务日志直推**：进程在内存里生成结构化事件，HTTP 直推免落盘、免转发器
- **定时任务/脚本回传结果**：跑完一段业务逻辑，把结果 JSON 推进来，秒级可查
- **何时不用**：已有文件日志的存量系统（monitor/Forwarder 更省事）；单机超低吞吐场景（一条 curl 也要先建 token，不值）

| 入库通道 | 差异 | 什么时候选它 |
|:---|:---|:---|
| HEC（本实验） | 进程直推、实时、JSON 结构化 | 容器/服务/脚本 |
| oneshot（lab 01/02） | 文件一次性灌入 | 静态文件、一次性 |
| Forwarder（lab 08） | 常驻代理读文件、断网续传 | 存量文件日志 |

## Quick Start

前置：lab 01 实例（compose 已预留宿主 28088→容器 8088）。

```bash
cd splunk/07_spl_hec
./spl_hec.sh all   # up → deploy → ack → batch → timecheck → clean
```

`ack` 与 `batch` 的真实输出（节选）——ack 两轮翻转、1 万条 0.13 秒发完、对账差额 0：

```
=====> [ack] 单事件 ack 回执：POST event → ackId → POST ack → true
        event 响应: {"text":"Success","code":0,"ackId":0}
        ack 响应:   {"acks":{"0":true}}（第 2 轮）
        ✅ 断言 A：ackId=0 经 /ack 确认翻转 → true（索引器回执语义）
=====> [batch] 1 万条批量产生 + 入库数对账
        产生器摘要: {"channel": "083f...", "sent": 10000, "batches": 20, "failures": 0, "seconds": 0.13, ...}
        ✅ 断言 B：入库数 = 发送数 = 10000（差额 0，已排除 ack 演示事件）
```

`timecheck` 的事件时间实证（节选）——_time 逐秒贴合事件内 time 字段，与接收时刻差 5400s：

```
        ✅ 断言 C1：_time 范围与事件时间一致（base/last ±3s 内）
        _indextime-_time ≈ 5400s（产生器把事件时间预置在过去 5400s，接受即验证）
        ✅ 断言 C2：入库时间滞后 ≈5400s → _time 取自事件内 time 字段（非接收时刻）
```

诚实预期：`all` 全程约 5-6 分钟（两次 splunkd 重启各约 60-85 秒是大头；1 万条事件本体 0.13s 发完、入库收敛数秒）。`clean` 删 hec_demo 索引与 inputs.conf 并重启，HEC 回到停用状态。

## How It Works

**ack 的工作流**。token 配 `useACK = true` 后，每次事件 POST 的响应多一个 `ackId`；客户端拿 ackId POST `/services/collector/ack`，应答里 `acks` 从 false 翻转为 true。

true 的含义是"这个事件已被索引管道处理完"，不是"HTTP 已收到"。两个实测细节：ack 模式**强制要求** URL 带 `?channel=<32位hex>`——channel 是 32 位十六进制的数据通道标识，HEC 用它区分并发的推送流、并把 ack 回执挂到对应通道上，不带直接被拒。

响应形态是 `{"acks": {"0": true}}` 这样以 ackId 为键的对象，不是文档示例的数组。

**为什么先建索引**。目标索引 hec_demo 不存在时：事件 POST 照样返回 code=0、ack 照样给 ackId，但事件在路由阶段被静默丢弃（实测：入库 0 条）。

HEC 的 intake（HTTP 接收）与 indexing（索引管道）解耦，HTTP 成功只覆盖前者。本实验 deploy 第一步就是建索引，再发事件——"响应成功"必须靠搜索对账来背书，这就是断言 B 存在的意义。

**_time 的归属**。事件对象里的 `"time": <epoch>` 直接成为事件的 `_time`：断言 C1 对照产生器的 base/last 时间戳（±3s 内逐秒一致）。

断言 C2 的 `eval lag_s=_indextime-_time | stats max(lag_s)` 显示滞后恰为 5400s——产生器把事件时间预置在过去 1.5 小时，若 Splunk 用接收时刻当 _time，这个滞后不会出现。time 字段缺省时才回落到接收时刻。

## Pitfalls & Q&A

- **目标索引不存在 → 事件静默丢弃**：HTTP 层 code=0、ack 都有，就是不入库。解法：deploy 先建索引；"发送成功"必须用搜索对账验证
- **ack 模式不带 channel 被拒**：`Missing data channel`。解法：URL 追加 `?channel=<uuid hex>`，同一批次用同一 channel
- **ack 立即查询是 false**：false 只说明"还没处理完"，轮询到 true 才是承诺。解法：轮询 /ack（本脚本 ≤60s，实测第 2 轮翻转）
- **`stats max(_indextime-_time)` 空结果**：stats 聚合里不能写算术表达式。解法：先 `eval lag_s=_indextime-_time` 再 `stats max(lag_s)`（lab 02 同款规则）
- **对账多出 ack 演示事件**：ack 步骤的事件混进批量计数（10002≠10000）。解法：演示事件带独立 path 标记，对账查询 `path!=/ack-demo` 排除

**Q1：批量发送怎么带结构？** 一个 HTTP 请求的 body 是多行 JSON——每行一个完整事件对象，500 条一批实测秒发。行内 `"event"` 可以是任意 JSON（本实验是业务字段对象），顶层 `index/sourcetype/host/time` 是路由与解析元数据。

**Q2：HEC 和 lab 08 的 Forwarder 怎么分工？** HEC 是进程主动推（推模型，适合内存里刚生成的数据）；Forwarder 是代理读文件转发（拉文件模型，适合已有日志文件、断网续传）。两者可并存：容器里进程推 HEC，宿主机文件交给 Forwarder。

**Q3：token 明文写在 inputs.conf 安全吗？** 实验环境可行（token 随仓库公开、容器单机）；生产环境 token 是凭据——走密钥管理注入、限定允许的索引、按来源分 token。

inputs.conf 的 `[http://hec_lab]` 段还支持 `index` 缺省值与 SSL 配置，收窄面在配置层完成。
