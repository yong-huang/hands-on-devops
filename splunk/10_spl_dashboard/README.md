# 10 · 运维仪表盘：JSON 定义即验收对象

> 四图盘（访问量趋势 / 错误率曲线 / 状态码分布 / 错误样例表）写成 Dashboard Studio JSON，脚本从 JSON 里提取每个 panel 的查询、经 REST 逐条执行并断言有数据——"仪表盘画好了"和"仪表盘有真实数据"从此是两件被分开验证的事。读完你能带走：一份 Studio 定义模板，和"panel 查询可进 CI 复跑"的验收方法。

## Background

仪表盘的验收陷阱是"看得见就当有数据"：图表画出来了（哪怕是空坐标轴），截图一贴就算交付。面板背后的查询到底有没有返回数据、返回多少行，UI 截图全都无法背书。

之前的统计管道（lab 04）已经证明 SPL 查询可以被独立验证；本实验把同样的思路套到仪表盘上——把每个 panel（面板，即仪表盘上的一张图）的查询提取出来、经 REST 逐条执行、断言行数 >0。查询有数据 + 定义入库 git，仪表盘的正确性就有了机器背书。

## What

dashboard.json（Dashboard Studio 格式——Splunk 新一代仪表盘的定义格式，整张仪表盘用一份 JSON 声明）的三层结构与四图分工：

| 层 | 内容 | 本实验取值 |
|:---|:---|:---|
| dataSources | 数据源（每 panel 一条 SPL + 时间参数） | 4 条，全部挂 `refresh: 30s`（自动刷新） |
| visualizations | 可视化（类型 + 标题 + 绑定数据源） | line × 2 / pie × 1 / table × 1 |
| layout | absolute 布局（x/y/w/h） | 2×2 网格，1440×960 |

可以把 dataSources 想象成"每张图各自的取数管道"、visualizations 是"画法"——但和画图软件不同，Studio 的 JSON 是声明式的：改查询只动 dataSources，改布局只动 layout，两者互不干扰（且都可进 git）。

四 panel 的实测行数：趋势 8 行（数据跨 7 天、覆盖 8 个日界桶，桶桶非空）、错误率 8 行、状态码分布 9 行、错误样例 10 行——全部 >0。

![dataflow](images/spl_dash.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/10_spl_dashboard/images/spl_dash.html)
> （或本地打开 [`images/spl_dash.html`](images/spl_dash.html)）。

## When to Use

- **运维概览页**：趋势/错误率/分布/样例四件套覆盖日常值守视角，换 index 与字段即可复用
- **查询质量回归**：panel 查询进 CI 复跑——数据源字段改名、索引迁移时第一时间爆红
- **何时不用**：一次性临时分析不值得建盘（rex+SPL 即可）；需要复杂交互钻取（点击图上元素跳进更细一层数据）的场景，Studio 的 table 联动有限

| 产出方式 | 差异 | 什么时候选它 |
|:---|:---|:---|
| Studio JSON（本实验） | 声明式、可进 git、可 REST 验证 | 团队共享的正式仪表盘 |
| UI 拖拽 | 快但不可复跑 | 个人探索 |
| SimpleXML | 旧格式、生态成熟 | 兼容存量面板 |

## Quick Start

前置：lab 01 实例 + lab 02 教程数据（不足自动补灌）。

```bash
cd splunk/10_spl_dashboard
./spl_dash.sh all   # up → verify → clean
```

`verify` 的两道断言真实输出（节选）：

```
=====> [verify] dashboard.json → 提取 4 查询 → REST 断言
        ✅ 结构断言：4 数据源 / 4 可视化 / absolute 布局 / 自动刷新 30s 全配置
        ✅ panel[viz_qps] 访问量趋势（按天） —— 8 行
        ✅ panel[viz_status] 状态码分布 —— 9 行
        ✅ panel[viz_sample] 最新错误请求样例 —— 10 行
        ✅ 4/4 panel 查询全部有数据
```

诚实预期：`all` 约 1-2 分钟（数据已在库时纯 REST 执行，秒级）。本实验不向 Splunk 导入仪表盘——Studio JSON 在 UI"添加仪表盘 → 导入"一次点击即可上屏，验收聚焦"panel 查询真实有数据"。`clean` 只清 tmp。

## How It Works

**JSON 即契约**。提取逻辑走 Studio 的标准链路：visualization 的 `dataSources.primary` 指向 dataSources 键 → 取 `options.query`。

结构断言先跑（4 数据源 / 4 可视化 / absolute 布局 / 每个数据源带 `refresh: "30s"`）——refresh 就是 Studio 的自动刷新配置，等价于旧版面板的 autoRefresh 语义。

**REST 执行的公平性**。panel 查询原样提交（含 `earliest_time=0`——教程数据跨 7 天，UI 默认时间窗搜不到的坑在 lab 02 已记录）。断言的是"行数 >0 且无 ERROR/FATAL"，不是具体行数——行数随数据量变化，有数据才是 panel 存在的意义。

**为什么不做 UI 截图验收**。截图验证的是"渲染正常"，REST 验证的是"数据真实"——后者可进 CI（每次改 dashboard.json 自动复跑），前者只能靠人眼。两者互补：JSON 入库 + REST 断言保正确性，导入 UI 后人工看一眼保美观。

## Pitfalls & Q&A

- **教程数据 7 天跨度和 UI 默认时间窗错位**：查询必须显式 `earliest: 0`（Studio 里是 queryParameters）——不然 panel 永远空。解法：JSON 里 queryParameters 全部带 earliest/latest
- **refresh 配错位置**：Studio 的自动刷新在 **dataSource** 的 options 里（`refresh: "30s"`），不是顶层 layout——配错位置面板不会自动刷
- **panel 查询引用了不存在的字段**：REST 执行会报 ERROR 而不是返回空——结构断言之后的执行断言会抓到。解法：字段名以 `| fieldsummary` 实测为准

**Q1：Studio 和 SimpleXML 怎么选？** 新面板选 Studio（JSON、组件化、持续演进）；存量 SimpleXML 面板不必迁移。两者的搜索层语法一致，本实验的"提取查询→REST 验证"方法对两者通用。

**Q2：refresh 30s 会不会打爆索引器？** 不会——四个数据源都是搜索作业，30 秒一次的调度压力等效于四个慢速用户。正式环境的重查询用 scheduled search + summary index（lab 04/06 的思路）做前置加速，面板只读结果。

**Q3：panel 行数为什么要 >0 而不是断言精确值？** 教程数据固定时可以断精确值，但仪表盘服务的常态是"数据持续流入"——断言精确行数会让数据增长时误报。>0 加"无报错"就是"panel 活着"的最小充分证据。
