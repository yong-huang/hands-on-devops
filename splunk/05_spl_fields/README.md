# 05 · 字段工程：rex、REPORT 与两级参照验证

> access_combined 是标准格式、出厂自带字段解析；换成自家日志就得自己造字段。本实验把手写提取的两条路（rex 内联、REPORT 配置化持久）都走一遍，并各配一层独立参照验证：rex 对照出厂解析（20/20），REPORT 对照 Python 独立解析（20/20）。读完你能带走：一份可直接复用的 props/transforms 配置模板，和"提取正确性"的两种证明方法。

## Background

lab 03/04 的 SPL 之所以能直接写 `status`、`clientip`，是因为官方 sourcetype 自带解析规则。真实世界里大量日志没有这种待遇：字段埋在 `_raw` 里，每次查询都要现写提取逻辑——写错一格，整个报表跟着错。

Splunk 给了两条造字段的路：rex 命令在查询里内联提取，适合探索；props.conf/transforms.conf 把提取规则配置化，团队共享、随 sourcetype 永久生效。

两条路的正确性都不能靠肉眼——本实验给 rex 找的参照是出厂解析（同一条 `_raw`，手写提取的值必须与出厂字段一致），给 REPORT 找的参照是 lab 04 同款的 Python 独立解析（20 条逐字段比对）。

## What

字段提取的三条途径与适用场景：

| 途径 | 写在哪 | 何时用 |
|:---|:---|:---|
| 出厂内置 | sourcetype 自带 | 标准格式，零配置 |
| rex 内联 | 每条 SPL 里 | 临时探索、一次性报表 |
| REPORT 持久 | props/transforms.conf | 团队复用、非标准 sourcetype |

可以把 rex 想象成"在查询里临时贴一条正则"，REPORT 则是"把同一条正则写进户口本"——但和贴便签不同，REPORT 挂在 sourcetype 上：一旦配置，**已入库的旧事件也会立即出新字段**（搜索时提取，不改历史数据、不需重灌）。

本实验的自定义 sourcetype 叫 `splk_access_lab`：20 条样本入库到独立索引 `splk_fields_lab`，搜索时 clientip/method/uri/status/bytes/referrer 等八个字段自动出现。

（transforms 的 FORMAT 共映射 8 个，另含 ts、useragent。）

![dataflow](images/spl_fields.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/05_spl_fields/images/spl_fields.html)
> （或本地打开 [`images/spl_fields.html`](images/spl_fields.html)）。

## When to Use

- **非标准日志接入**：自家应用日志格式固定但没有现成 sourcetype——REPORT 一次配置、所有查询受益
- **临时字段探索**：先 rex 验证正则可靠，再固化成 REPORT——本实验的两条路就是这条演进路径
- **何时不用**：字段已在出厂解析里时重复造轮子（rex 出来的值与内置一样，白写）；提取规则要在**入库时**落盘过滤/路由的，用 INDEXED_EXTRACTIONS 而不是 REPORT（搜索时提取）

| 方式 | 差异 | 什么时候选它 |
|:---|:---|:---|
| rex 内联 | 零配置、随查询走 | 探索、单次分析 |
| REPORT（本实验） | 配置化、团队共享 | 固定格式的长期解析 |
| UI Field Extractor | 点选生成、存为权限对象 | 不想写正则的快速草图 |

## Quick Start

前置：lab 01 实例 + lab 02 教程数据（不足自动补灌）。

```bash
cd splunk/05_spl_fields
./spl_fields.sh all   # up → rex → persist → verify → clean
```

`rex` 步骤的真实输出（节选）——命名捕获（用 `(?P<名字>…)` 给正则捕获组起名，匹配结果直接变成字段）从 `_raw` 提出六个字段，下表展示其中五个业务字段，20 条与出厂字段全一致：

```
=====> [rex] rex 内联提取 vs 出厂内置字段（同事件对照，≥19/20）
        rex_clientip=91.205.189.15  rex_method=GET  rex_uri=/oldlink?itemId=EST-14&JSESSIONID=SD6SL7FF7ADFF53113  rex_status=200  rex_bytes=1665
        ✅ rex 提取正确率 20/20（≥19/20，参照=出厂内置解析）
```

`verify` 的两条断言（节选）——REPORT 提取的字段不写 rex 直接出现，且与 Python 独立解析逐条一致：

```
=====> [verify] REPORT 字段自动出现 + Python 独立对照（20/20）
        clientip=182.236.164.11  method=GET  uri=/cart.do?action=addtocart&itemId=EST-12&productId=WC-SH-G04&JSESSIONID=SD6SL8FF10ADFF53101  status=200  bytes=2833  referrer=http://www.buttercupgames.com/product.screen?productId=WC-SH-G04
        ✅ 断言 A：REPORT 提取的字段搜索时自动出现（未写任何 rex）
        Python 独立对照：20/20 条四字段完全一致
        ✅ 断言 B：REPORT 字段值与 Python 独立解析 20/20 一致
```

诚实预期：`all` 全程约 4-5 分钟（含两次 splunkd 重启，各约 60 秒）；重复跑 `all` 幂等（persist 会先删旧 lab 索引再重建，样本不翻倍）。`clean` 删 lab 索引、删容器内配置并重启，出厂解析不受影响。

## How It Works

**rex 的命名捕获**。`rex field=_raw "^(?P<rex_clientip>\S+) ..."` 对每条 `_raw` 跑正则，`(?P<名字>...)` 把捕获组直接变成字段。字段名加 `rex_` 前缀是为了不与出厂字段冲突——出厂的 `clientip` 已存在，同名覆盖会让验证失去意义。

**REPORT 的配置链路**。props.conf 声明 `[splk_access_lab]` 的行切分与时间戳规则，并用 `REPORT-access = splk_access_extract` 指向 transforms.conf 里的 `REGEX`/`FORMAT`。

REGEX 用捕获组切出 8 段，FORMAT 把 `$1..$8` 映射成字段名。配置经 docker cp 落到容器 `system/local/`，`docker compose restart` 后生效——配置只在启动时读，这一步省不得。

**两级参照的取材**。rex 的参照是出厂解析：同一条事件里 `rex_clientip==clientip` 等三组比对，20/20 说明手写正则与官方解析器同口径。

REPORT 的参照是 Python 独立解析（正则与 lab 04 的 crosscheck 同源）：样本入库后按 `_raw` 逐条对回原文件，四字段完全一致才通过——你在断言 B 看到的 20/20，就是配置化提取与独立实现的双向确认。

## Pitfalls & Q&A

- **改了 props/transforms 不重启、不生效**：配置只在 splunkd 启动时读取。解法：`docker compose restart`（约 60 秒），重启后旧事件的新字段立即出现
- **oneshot（同步执行、结果随响应返回的搜索模式）后"count=20 但 table 只回 1 行"**：检索可见性异步收敛，计数达标不代表下一次查询看得到全部。解法：轮询**目标查询本身**直到返回完整行数（本脚本 verify 即如此）
- **正则锚死行尾 `$` 会漏配**：教程 access 行 `_raw` 尾部还有一段响应时间数字（`... "UA" 349`），锚 `$` 一条都匹配不上。解法：只锚结构、放开行尾
- **清理配置时报 Permission denied**：默认 exec 用户是 ansible(999)，删不了 splunk 属主的文件。解法：`docker exec -u root ... rm`

**Q1：REPORT 是搜索时提取，会不会很慢？** 每次搜索都要现跑正则，代价存在；但 access_combined 这类结构规整的行，正则成本远低于检索本身。追求入库时算好的场景才需要 INDEXED_EXTRACTIONS（字段落盘、搜索零成本），代价是改规则后必须重灌数据。

**Q2：为什么样本取自 tutorial 的 `_raw` 而不是原始文件？** 取 `_raw` 让"入库前"与"入库后"的文本完全一致，验证时按 `_raw` 逐条对回——排除文件轮转、编码差异等无关变量，对照只反映提取逻辑本身。

**Q3：字段别名（alias）算第四条路吗？** 算——`EVAL-` 与字段别名也写在 props.conf，只是它们不解析 `_raw`，而是对已有字段做改名或派生。本实验的三条路覆盖"从 `_raw` 造字段"的主线，别名属于字段加工的延伸。
