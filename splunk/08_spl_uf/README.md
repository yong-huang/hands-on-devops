# 08 · Universal Forwarder：文件采集链与断网续传

> 用 UF（Universal Forwarder，Splunk 的常驻采集代理）盯挂载目录里的日志文件，经 TLS 9997 转发给索引器：100 行 10 秒入库、停机写 30 行复启后 0 丢失。读完你能带走：UF 容器的完整配置（monitor + outputs）、索引器侧 TLS 接收的配置模板，和"续传不丢"的实测证据。

## Background

lab 07 的 HEC 解决"进程内存里的数据"；反过来，大量存量系统的数据已经写成文件——应用日志按行追加、错一行漏一行都心疼。手写 tail 脚本能读文件，但记住读到哪里、断网了怎么办、文件轮转怎么办，都要自己造轮子。

UF（Universal Forwarder）就是官方造好的轮子：常驻代理盯文件、按偏移量追读、断网/停机自动续传。本实验在 Apple Silicon 上以 amd64 模拟跑 UF 容器，把"采集链不断"这件事做成两条可复跑的断言。

## What

采集链的四段结构与配置分工：

| 环节 | 配置 | 内容 |
|:---|:---|:---|
| 文件源 | 宿主挂载目录 | app.log 按行追加 |
| UF 容器 | `inputs.conf` | `[monitor:///opt/data/app.log]` → index=uf_demo |
| UF 容器 | `outputs.conf` | `server = splunk-deploy:9997`（s2s——Splunk 的转发协议——自动协商 TLS） |
| 索引器 | `inputs.conf` + 证书 | `[splunktcp-ssl:9997]` + serverCert（自签的服务端证书参数，要求"证书+私钥"合并 PEM，见 Q1） |

可以把 UF 想象成"自带书签的跟读员"——读到哪记到哪（fishbucket 偏移量），离开再回来接着读。但和书签不同，它追的是文件的字节偏移：停机期间新写入的行，恢复后从上次位置起全部补齐，一行不落。

实测结论：100 行写入后 10 秒入库；停机 30 秒期间写入 30 行，复启后 30 行全部补齐（0 丢失）。

![dataflow](images/spl_uf.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/08_spl_uf/images/spl_uf.html)
> （或本地打开 [`images/spl_uf.html`](images/spl_uf.html)）。

## When to Use

- **存量文件日志接入**：应用已写文件、不能改代码推 HEC——UF 是无侵入方案
- **断网容错场景**：采集点与索引器之间网络不稳，UF 的本地缓冲与续传兜底
- **何时不用**：数据是进程内存态（走 HEC，lab 07）；只灌一次的静态文件（oneshot 更轻，lab 01）

| 入库通道 | 差异 | 什么时候选它 |
|:---|:---|:---|
| HEC（lab 07） | 进程直推 JSON | 内存里刚生成的数据 |
| UF（本实验） | 读文件、可续传 | 存量文件日志 |
| oneshot（lab 01） | 一次性手工灌 | 临时文件、静态数据 |

## Quick Start

前置：lab 01 实例；UF 镜像 `splunk/universalforwarder:9.4`（amd64——官方无 arm64，拉取命令同 lab 01 模式）。

```bash
cd splunk/08_spl_uf
./spl_uf.sh all   # up → ufup → ingest → blackout → clean
```

`ingest` 与 `blackout` 的真实输出（节选）——两条断言：

```
=====> [ingest] 写 100 行 → 120s 内入库对账
        ✅ 断言 A：100 行入库（≥100，约 10s）
=====> [blackout] 停 UF → 写 30 行 → 复启 → 续传不丢
        [ok] 停机期间写入 30 行（run=B）
        ✅ 断言 B：停机期间 30 行续传入库（run=B 30 条，0 丢失）
```

诚实预期：`all` 全程约 12-15 分钟——大头是 UF 首次引导（amd64 模拟下实测约 10 分钟，本仓所有容器引导之最）；数据链路本身很快（100 行 10 秒入库）。`clean` 删 UF 容器、9997 监听、证书与 uf_demo 索引，归零。

## How It Works

**TLS 9997 的两端配置**。索引器侧 `[splunktcp-ssl:9997]` 开 TLS 监听、`[sslConfig] serverCert` 指向自签的"证书+私钥合并"PEM。

UF 侧 outputs.conf 只写 `server = splunk-deploy:9997` 与 `sslVerifyServerCert = false`（后者只关"校验服务端证书"这一件事——自签证书验不了才写 false，不是开加密的开关）。

s2s（forwarder-to-indexer 协议）自带加密协商：UF 发起握手时声明支持 SSL，索引器 SSL 监听应答后两边自动切到 TLS——UF 侧不需要额外开关。

**续传的机理**。UF 在 fishbucket（本地偏移量数据库）记录每个被监控文件的读入字节位置；停机期间文件增长不读，复启后从记录位置继续——这就是断言 B 的 30 行能补齐的原理。

对账用行内 `run=B` 标记独立计数，与先到的 100 行（run=A）互不干扰。

**9997 监听的确认方式**。容器里没有 netstat，用 `/proc/net/tcp` 查端口 9997（十六进制 270D）的 LISTEN 记录；UF 侧用 splunkd.log 的 `Connected to idx=` 日志（每 30 秒打一条连接信息）双证。

## Pitfalls & Q&A

- **UF 的 SPLUNK_HOME 是 `/opt/splunkforwarder` 不是 `/opt/splunk`**：二进制、配置、日志全在 splunkforwarder 下——docker cp 路径写错就是无效配置（实测踩过）
- **UF 容器内 `splunk status` 要 `-u root`**：镜像默认 exec 用户是 ansible(999)，直接跑会触发 chown 失败（Operation not permitted）
- **目标索引不存在 → 转发静默丢弃**：与 lab 07 的 hec_demo 同款（intake≠indexing）——UF 转发成功≠入库成功，uf_demo 必须先建。解法：up 步骤先建索引（./spl_uf.sh up）+ 搜索对账背书
- **新文件生效是异步的**：docker cp 配置后 splunkd.log 的连接建立、monitor 生效都有数秒延迟。解法：全部轮询（引导日志 "Ansible playbook complete"、`Connected to idx=`、搜索对账）
- **UF 首次引导约 10 分钟**：amd64 模拟下 ansible provisioning 之最，轮询上限给足 900 秒

**Q1：TLS 为什么要合并证书与私钥？** Splunk 的 `serverCert` 参数要求一个同时含证书与私钥的 PEM 文件（证书在前、私钥在后）——拆成两个文件它不认。本实验用 `openssl req -x509 -nodes` 生成无口令密钥再 cat 合并。

**Q2：UF 和 HEC（lab 07）推同一种数据会重复吗？** 会——两条通道独立计数，同一条日志走 UF 和 HEC 就是两份事件。lab 12 的终极串联用"HEC 报结构化事件 + UF 采集文件日志"分工：同一服务的两个视图，靠请求 ID 关联而不是去重。

**Q3：`monitor` 与 `oneshot` 对同一文件会双份吗？** 会——oneshot 是独立的一次性灌入，monitor 是持续追读，两者对同一文件互不知情。实验间用不同 index/sourcetype 区分，避免对账串扰。
