# 02 · 教程数据入库：四元组——Splunk 的数据坐标系

> 把官方教程数据集（Buttercup Games 电商日志）灌进 lab 01 的 Splunk，并逐文件标注 index/sourcetype/source/host 四元组。读完你能带走：一条国内可用的下载链路、oneshot（不经采集管道、CLI 直接把一个文件灌进索引的最轻量命令）四元组入库的完整命令、三条可复跑的验收断言。

## Background

练 SPL（Splunk 的检索语言，从 `search` 命令开始、以管道连接处理命令）需要一份稳定、可对照官方文档的数据集——自己现场造日志，每条 SPL 的结果都无法和别人对答案。

Splunk 官方为此准备了教程数据：一套虚构电商 Buttercup Games 的服务器日志（Web 访问、sshd 认证、支付流水），事件字段丰富、规模适中。

拿它入库会先撞上两件事。其一，下载就卡住：`docs.splunk.com` 对非浏览器请求返回 403，直连又限速到约 1.5KB/s。其二，"数据从哪来、怎么被切分"在 Splunk 里由四个元数据字段共同决定，第一次接触很抽象，值得用同一份数据、8 个文件逐个标注重复体会。

## What

Splunk 用四个元数据字段描述每条事件的出身，合称四元组：

| 字段 | 含义 | 本实验取值 |
|:---|:---|:---|
| index | 索引库，数据落在哪个库 | `tutorial` |
| sourcetype | 解析规则，按什么格式切字段 | `access_combined_wcookie` / `linux_secure` / `vendor_sales` |
| source | 来源路径，文件从哪来 | `www1/access.log` 等 |
| host | 主机标注，谁产生的 | `www1` / `www2` / `www3` / `mailsv1` / `vendor001` |

可以把四元组想象成图书馆的编目：index 是分馆（进去先选馆），sourcetype 是书籍类型规则（决定怎么读），source 是书架位置，host 是捐赠者。但和图书馆不同，Splunk 的"编目"是在数据**进入时**由采集方标注的——同一条原始日志，标注不同，检索行为就不同。

每条事件（Splunk 入库后的每条独立记录）还自带三个默认字段：`_time`（事件时间，从内容解析）、`_indextime`（入库时间）、`_raw`（原始全文）。

![dataflow](images/tutorial_data.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/02_tutorial_data/images/tutorial_data.html)
> （或本地打开 [`images/tutorial_data.html`](images/tutorial_data.html)）。

## When to Use

- **练 SPL / 对官方文档答案**：教程数据事件量大、字段固定，官方 Search Tutorial 的每条示例 SPL 都能复跑
- **讲清采集概念**：8 个文件、5 台主机（3 类角色）、3 种 sourcetype，规模刚好够演示四元组的每个维度
- **何时不用**：要练真实接入链路（HEC 即 HTTP Event Collector，JSON 事件入库通道；Forwarder 即 Universal Forwarder，装在数据源上的轻量采集代理）时，教程数据帮不上——那是后续实验的通道；生产数据更不该手工 oneshot

| 数据来源 | 差异 | 什么时候选它 |
|:---|:---|:---|
| 教程数据集（本实验） | 官方出品，文档可对照 | 学 SPL / 讲概念 |
| 自建产生器 | 字段自己定 | 模拟特定业务形态 |
| 真实服务日志 | 最真但不可控 | 接入链路联调 |

## Quick Start

前置：lab 01 的 Splunk 实例已部署（`splunk/01_splunk_deploy`），其 `.env` 存有 admin 密码。

```bash
cd splunk/02_tutorial_data
./tutorial_data.sh all   # up → download → ingest → observe → clean
```

`download` 与 `ingest` 的真实输出（节选）——下载走容器内代理（VM 出口秒级），8 个文件逐个入库：

```
=====> [download] 下载 tutorialdata.zip（完整浏览器 UA；curl 默认 UA 实测 403）
        [ok] 1955047 字节，zip 完整
=====> [ingest] 解包 + 建 tutorial 索引 + 逐文件 oneshot（四元组显式指定）
        oneshot www1/access.log → sourcetype=access_combined_wcookie host=www1
          → 13628 条已可检索
        oneshot vendor_sales/vendor_sales.log → sourcetype=vendor_sales host=vendor001
          → 30244 条已可检索
```

`observe` 的四元组全景表与三条断言（节选）——`tstats`（Splunk 的快速统计命令，只读索引元数据、不碰原始日志）按 sourcetype × host 给出全景，三条断言全绿：

```
        access_combined_wcookie  host=www1         count=13628
        linux_secure             host=mailsv1      count=9829
        vendor_sales             host=vendor001    count=30244
        ── 默认字段对照（事件时间 vs 入库时间）──
        _indextime-_time 最大滞后: 705155 秒（事件时间早于入库时间越多，滞后越大）
        ✅ 断言1：index=tutorial 总事件 = 109864（≥1000）
        ✅ 断言2：sourcetype 3 种（≥3）
        ✅ 断言3：host 5 台（≥2）
```

诚实预期：8 个文件入库合计约 6-8 分钟（Rosetta——Apple 的 x86→ARM 二进制转译层——模拟下索引 18.9MB 原始数据）。`clean` 只删 tutorial 索引和 tmp，Splunk 实例归 lab 01 管、不停机。

## How It Works

**下载为什么走容器内**。docs.splunk.com 的 WAF（Web Application Firewall，Web 应用防火墙）按 User-Agent 拦非浏览器请求：默认 curl UA 直接 403，带完整浏览器 UA 才放行。

放行后宿主直连只有约 1.5KB/s——但 OrbStack（macOS 上的容器运行环境，Docker Desktop 的替代品）的虚拟机出口（Docker 拉镜像走的那条代理链路）很快，所以下载放在容器里执行，几秒完成。

**oneshot 的四元组参数**。`splunk add oneshot <文件>` 是最轻量的入库通道：CLI 同步读取文件、解析、写入索引后返回。

四元组里除 index 外的三项都在命令行显式指定：`-sourcetype` 给解析规则、`-rename-source` 覆盖 source（默认会是容器内文件路径）、`-hostname` 覆盖 host。

你在 observe 输出里看到的 host=www1，就来自这一行命令的 `-hostname www1`。

**REST 搜索的前缀规则**。lab 01 已确认 REST 的 search 参数不自动补隐式 `search` 命令；本实验再补另一半：生成型命令（`tstats`，以及 `|` 开头的管道）不能加前缀——`search | tstats` 是非法语法，会静默返回空结果。

而 `| eval` 这类转换型命令开头等于零输入事件，同样空结果——必须以 `index=tutorial` 起头让搜索先产生事件流。

**tstats 为什么快**。`| tstats count where index=tutorial by sourcetype` 只读 tsidx（索引元数据文件，记录"哪个词在哪些事件出现"），完全不碰 `_raw` 原文；普通 `stats` 要先检索事件再聚合。

全景表用 tstats，几百万事件也能秒回。

## Pitfalls & Q&A

- **curl 默认 UA 403**：docs.splunk.com 的 WAF 只放行浏览器 UA。解法：完整 Chrome UA；速度慢再叠加容器内代理
- **按 Content-Length 断言下载完整性失败**：实测同一 URL 的 HEAD 报 1955044，GET 拿到 1955039-1955097——CDN（Content Delivery Network，内容分发网络，同一文件缓存在多个节点上）节点内容不一致。解法：只断言 PK 魔数（zip 文件头两字节）与体积下限，不断言精确大小
- **oneshot 报 `Only one "name" parameter`**：`-host`/`-source` 是 `add monitor` 的参数，oneshot 用 `-hostname`/`-rename-source`
- **`| eval` 开头的搜索空结果**：转换型命令开头没有输入事件。解法：以 `index=tutorial` 起头
- **UI 里搜不到教程数据**：教程事件时间为 2026-11-07，默认"最近 7 天"差一天就搜不到。
  解法：时间范围调 All time（脚本内 SPL 均显式 `earliest_time=0`）

**Q1：host 字段和日志内容里的主机名什么关系？** 无关。host 是采集方标注的输入元数据（本实验来自 `-hostname` 参数）；`linux_secure` 日志的 `_raw` 里虽带有 `www1` 字样，但不经提取不会成为 host 字段。

想从内容推导 host 要另配 props/transforms（Splunk 的字段提取配置体系），属于后续字段工程实验。

**Q2：zip 直接上传 UI 和解包后逐文件入库，结果一样吗？** 不一样。UI 上传 zip 时 sourcetype/host 靠自动识别，结果不可控；逐文件入库把四元组写死在命令行，可复跑可断言——本实验选后者，README 记录的就是这套确定值。

**Q3：为什么断言 3 数出 5 台 host？** 8 个文件映射到 5 个标注：三台 Web 服务器（www1/2/3）、邮件服务器（mailsv1）、支付供应商（vendor001）。host 数与目录数不必相等——标注是人为约定，这正是四元组"编目"属性的含义。
