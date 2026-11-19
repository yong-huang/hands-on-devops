# 06 · lookup 数据富化：三张字典接入事件流

> 给 39,532 条 access 事件挂上三类外部知识——状态码语义、UA 设备分类、服务器资产——并做四条断言（null 率 / 行数一致 / outputlookup 回读）与 join 同题计时。读完你能带走：三种匹配形态（精确/WILDCARD/资产映射）的配置模板，和"join 慢在子搜索"的实测证据。

## Background

日志本身只有原始字段：status 是一个数字，useragent 是一长串机器串，host 是一台机器名——分析时反复要回答"这个码什么意思、这个 UA 是什么设备、这台机器归谁管"。之前的做法是在每条查询里现写 eval/case 判断，字典一变就要改 N 条查询。

lookup 把"字典"从查询里解放出来：一张 CSV + 一行 transforms 定义，任何查询都能按匹配键取回外部知识。

但字典也有自己的坑：UA 串里 Chrome 和 Safari 同时出现（先匹配谁？）、键没对上就出 null（字典漏配怎么发现？）、join 和 lookup 都能富化（到底谁快？）。本实验全部用断言回答。

## What

三张字典、三种匹配形态（数据：lab 02 教程数据，9 种状态码 / 26 种 UA / 5 台主机）：

| 字典 | 匹配方式 | 挂回字段 | 实测结论 |
|:---|:---|:---|:---|
| http_status.csv（35 行） | status 精确匹配 | status_desc | null 率 0/39532 = 0.0% |
| ua_class.csv（10 行） | WILDCARD（ua_prefix 带 `*`） | device_class/browser | 26 种 UA 全命中，null=0 |
| servers.csv（5 行） | host 精确匹配 | env/role/owner/region | 全部 host 覆盖，null=0 |

可以把 lookup 想象成"给每条事件贴外挂标签的登记处"——但和手工贴标签不同，它是搜索时按匹配键现场去字典里查的：字典更新一行，下一次搜索立即反映，历史数据不用动。

同题富化的计时（给每条事件标注"该状态码的事件总数"）：join 写法中位 0.49s，lookup 写法中位 0.22s——**lookup 快 2.2x**，慢的机理在 join 的子搜索每次都要全量扫描。

![dataflow](images/spl_lookup.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/06_spl_lookup/images/spl_lookup.html)
> （或本地打开 [`images/spl_lookup.html`](images/spl_lookup.html)）。

## When to Use

- **语义富化**：状态码→中文释义、UA→设备分类、host→资产归属——报表可读性的第一步
- **预聚合加速**：把昂贵统计 `outputlookup` 成字典，高频查询读字典不重算（summary index 思路的轻量版：把统计结果预先算好存进专用索引）
- **何时不用**：字典随事件高频变化时（每条事件自带键值，无需字典）；需要多表复杂关联时 lookup 表达不了，join/append 才合适

| 富化方式 | 差异 | 什么时候选它 |
|:---|:---|:---|
| lookup（本实验） | 字典静态、键匹配、快 | 字典知识、预聚合结果 |
| join 子搜索 | 实时、灵活、慢 | 两个数据集动态关联 |
| eval/case 硬编码 | 零字典、改则全改 | 两三个取值的琐碎判断 |

## Quick Start

前置：lab 01 实例 + lab 02 教程数据（不足自动补灌）。

```bash
cd splunk/06_spl_lookup
./spl_lookup.sh all   # up → deploy → enrich → perf → clean
```

`enrich` 的四条断言（节选）——null 率与行数全部零偏差：

```
=====> [enrich] 富化四断言
        ✅ 断言1：status_desc null 率 0/39532 = 0.0%（≤1%）
        ✅ 断言2：UA 设备分类 null = 0（26 种 UA 全命中 WILDCARD 字典）
        ✅ http_status: CSV 35 行 vs inputlookup 35 行
        ✅ outputlookup top_clients.csv 写入并回读 20 行
        ✅ 断言4：inputlookup 行数一致 + outputlookup 回读一致
```

`perf` 的计时对照（节选）——同题、同结果，中位耗时差 2.2 倍：

```
=====> [perf] 同题富化：join vs lookup 计时（各 3 轮取中位）
        结果一致（max(status_count)=34282）——公平计时
        lookup 中位耗时 0.22s | join 中位耗时 0.49s
        lookup 快 2.2x（✅ ≥2x）
```

诚实预期：`all` 全程约 4-5 分钟（含一次 60 秒配置重启与多组计时轮询）；`clean` 删全部字典与配置并重启归零。

## How It Works

**字典的部署链路**。CSV 落到容器 `/opt/splunk/etc/system/lookups/`，transforms.conf 用 `filename = xxx.csv` 注册匹配定义（WILDCARD 字典额外声明 `match_type = WILDCARD(ua_prefix)`），重启后生效。

搜索里 `lookup http_status status OUTPUT status_desc` 按 status 等值查表、把 status_desc 挂回事件。

**WILDCARD 与行序**。ua_class 的 ua_prefix 带 `*` 通配——但教程 UA 里 Chrome 与 Safari 同串（"…Chrome/19… Safari/536…"）。

CSV 行序即优先级：`*Chrome/*` 排在 `*Safari/*` 之前，Chrome 串先被 Chrome 行截住，真 Safari 才落到 Safari 行。爬虫三兄弟（Googlebot/YandexBot/Netcraft）同理按特异性排序，`*bot*` 兜底放最后。

**join 慢在子搜索**。对照题"每条事件标注该状态码的事件总数"：join 版的方括号子搜索每次执行都要全量扫描 39,532 条再聚合（实测 0.49s）；lookup 版读的是预聚合的 9 行字典（本地生成后 docker cp 进 system/lookups，缘由见下方坑 2，0.22s）。

字典法把"反复算"变成"算一次存起来"——正是 summary index 的轻量版。

## Pitfalls & Q&A

- **`| index=...` 是非法 SPL**：`index` 是 search 词不是生成型命令，管道开头不允许——outputlookup 会静默失败（本实验字典第一次就是没生成）。解法：以 `index=` 起头让补前缀规则接住
- **system 级 lookup 定义只从 system/lookups/ 解析文件**：REST 搜索上下文的 `outputlookup` 写进 `etc/apps/search/lookups/`（应用目录），system/local 的定义找不到它。解法：本地生成字典后 docker cp 进 system/lookups，与手工字典同款路径
- **REST 的"不补隐式 search"连子搜索也覆盖**：`join ... [index=...]` 直接报 Unknown search command。解法：子搜索内写 `[search index=...]`
- **新 lookup 文件生效是异步的**：docker cp 后立刻查询可能报 Could not construct——文件监视器延迟扫描。解法：轮询重试至成功
- **WILDCARD 行序即优先级**：字典按行序取第一个命中的行，特异行（Googlebot）必须排在通配行（`*bot*`）前面

**Q1：WILDCARD 匹配大小写敏感吗？** 字典值与字段值的匹配遵循 lookup 一致的比较语义——不要赌大小写：教程 UA 里的 Googlebot/YandexBot 都按原样大小写写在字典里，实测 26 种全命中。写字典时从真实数据 `stats count by 字段` 抄样本，是最稳的姿势。

**Q2：join 和 lookup 语义差异在哪？** join 是"两个搜索结果按字段关联"，子搜索实时、支持任意两侧、但默认 max=1（每行只取一条匹配，要 max=0 才全配）且慢；lookup 是"事件对静态字典"，只有字典一侧、快、字典可版本管理。

本实验同题对照两侧结果一致（max(status_count)=34282），差异只在代价。

**Q3：outputlookup 写进哪了？** REST 搜索的默认应用上下文是 search 应用——文件落在 `etc/apps/search/lookups/`，不是 `etc/system/lookups/`。system 级 lookup 定义解析不到它，这是本实验预聚合字典第一次没生效的根因。

后来的做法：语法修好后，本地生成 + docker cp 进 system/lookups，与手工字典同款路径。
