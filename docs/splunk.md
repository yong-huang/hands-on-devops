# 🔍 Splunk 数据观测 12 小项目学习清单 · Todo List（OrbStack 本机全跑通）

> 通过 12 个小项目（每项目 60-200 行配置/脚本/仪表盘）把 Splunk 从部署到观测闭环打通：部署地基 → SPL 分析 → 真实数据接入 → 可视化与告警
> 约束：本机 macOS + OrbStack 全跑通、零云依赖、全部免费（Splunk Enterprise 60 天试用 → 之后 Free 500MB/天）；⚠️ Splunk 官方镜像**无 arm64**，走 Rosetta 模拟 amd64（2026-11-15 实测，见文末速查表）
> 串联机制：阶段即能力等级——部署地基 → SPL 分析 → 数据接入 → 观测闭环；项目 12 🏁 终极串联（demo-web 服务的完整观测闭环）
> 预计周期：6 周（每天 1-1.5 小时）——**务必在 60 天试用窗口内完成**（告警调度是 Enterprise 专属）

## 🤖 AI 辅助提示词速查

| 场景 | 提示词 |
|:---|:---|
| **开始一个新项目** | `我要开始 Splunk 项目「[名称]」，目标是 [目标]。请给我完整配置/脚本约 [行数] 行（YAML/Bash/Python），macOS + OrbStack 本机可跑（Splunk 镜像 amd64 走 Rosetta），含可执行验收断言。只输出代码。` |
| **排障** | `我的 Splunk（Docker 单机，amd64 模拟）出现 [现象]，报错/日志：[粘贴]。请分析根因并给修复后的完整配置。` |
| **SPL 调优** | `这是我的 SPL：[粘贴]，在 tutorial 索引上结果不符合预期（贴结果）。请解释管道每步行为并给修正版 SPL。` |
| **写验收脚本** | `请为「[项目名]」写验收脚本：对产出逐条断言（参考清单验收标准），失败输出实际差异，全过打印 [ok]。` |

## 📊 总进度

进度：████████████████████ 12/12 (100%)

| 阶段 | 项目数 | 已完成 |
|:---|:---:|:---:|
| 第一阶段：部署地基与首搜 | 3 | 3 |
| 第二阶段：SPL 分析与知识对象 | 3 | 3 |
| 第三阶段：真实数据接入 | 3 | 3 |
| 第四阶段：可视化与告警闭环 | 3 | 3 |
| **合计** | **12** | **1** |

---

## 🗂️ 第一阶段：部署地基与首搜（项目 1-3）

> **目标**：起得来、进得去、搜得出——Splunk 在本机立起来并完成第一次真实搜索

### [x] 项目 1：Splunk Enterprise 单机部署（Rosetta 模拟 + 持久化）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~80 行 |
| **核心知识点** | 多架构镜像、Rosetta 2 模拟、Splunk 目录结构（etc/var）、license 类型、端口规划（8000/8089/8088/9997）、卷持久化 |
| **技术栈** | OrbStack + splunk/splunk:9.4（linux/amd64——拉取+boot 已实测：9.4.17 冷启动 ~45 秒，REST/Web 正常） |
| **⚠️ 风险** | 官方无 arm64 镜像（latest/10.0/9.4/9.3 全实测失败），依赖 Rosetta 模拟；**镜像源拉不动它**（1ms 坏层 / daocloud 白名单），必须走 OrbStack 代理直连 Docker Hub（命令见环境配置） |
| **验收标准** | `docker inspect` 报 `linux/amd64` 且 running；`curl -sk -u admin:<密码> https://localhost:8089/services/server/info` 返回含 `version` 的 XML；写入一条测试数据 → 重启容器 → 数据仍在（volume 持久化断言） |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「Splunk Enterprise 单机部署」。请给我完整 docker-compose.yml + 探活脚本约 80 行：splunk/splunk:9.4 用 --platform linux/amd64（Rosetta 模拟），SPLUNK_START_ARGS=--accept-license，密码环境变量化，端口 8000/8089/8088/9997，etc/var 双 volume 持久化，附等待 8089 REST 就绪的探活循环脚本与验收命令。只输出代码。`

**完成日期**：2026-11-15
**踩坑记录**：①telemetry.conf 挂 `:ro` 会让入口脚本递归 chown 失败、重试 60 次退出（bind mount 别加 :ro）；②镜像默认 exec 用户是 ansible(999)，CLI 操作必须 `docker exec -u splunk`；③REST 的 search 参数不自动补隐式 `search` 命令，裸 `index=main` 报 Unknown search command；④oneshot 后有秒级检索延迟，断言要轮询。全部修复并实证于 `splunk/01_splunk_deploy/`（apply→observe→clean 全过）

---

### [x] 项目 2：教程数据入库与数据四元组认知

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~60 行 |
| **核心知识点** | Add Data 上传向导、index/sourcetype/source/host 四元组、默认字段（_time/_raw/_indextime）、元数据搜索（tstats/metasearch） |
| **技术栈** | Splunk Web UI + tutorialdata.zip（⚠️ 下载需浏览器 UA，curl 默认 UA 实测 403） |
| **前置** | 项目 1 |
| **验收标准** | `index=tutorial \| stats count` ≥ 1000；`\| tstats count where index=tutorial by sourcetype` 分组 ≥ 3 种 sourcetype；`\| stats dc(host)` ≥ 2 台 host——三条 SPL 结果各截图或存档 |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「教程数据入库与四元组认知」。请给我约 60 行：tutorialdata.zip 下载脚本（带浏览器 UA）、导入步骤清单（Settings → Add Data → Upload → tutorial 索引）、以及验证 index/sourcetype/source/host 四元组的 SPL 速查卡 10 条（tstats/metasearch/重点字段说明）。只输出代码。`

**完成日期**：2026-11-15
**踩坑记录**：①docs.splunk.com 的 WAF 拦非浏览器 UA（403），直连又限速 ~1.5KB/s——容器内走 OrbStack 代理秒下；②同一 URL 的 Content-Length 与 GET 实际字节数每次都不同（CDN 节点不一致），只能断言 PK 魔数+下限；③`add oneshot` 的参数是 `-hostname/-rename-source`（`-host/-source` 是 monitor 的，混用报 Only one "name" parameter）；④REST 搜索：生成型命令（tstats/|开头）不能加 `search ` 前缀、`|eval` 转换型开头=零输入，必须 `index=` 起头。全部实证于 `splunk/02_tutorial_data/`（109864 事件/3 sourcetype/5 host 断言全过）

---

### [x] 项目 3：SPL 首搜——时间、字段与结果控制

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~60 行 |
| **核心知识点** | search 语法与布尔逻辑、时间修饰符（earliest/latest）、fields/table/rename/sort/head/dedup、eval 计算字段、where 过滤 |
| **产出模块** | `splunk/03_spl_basics/spl_cheatsheet.md`（个人 SPL 速查卡） |
| **前置** | 项目 2 |
| **验收标准** | 速查卡 ≥ 12 条 SPL，其中含 eval 与 where 的组合 ≥ 2 条；验收脚本批量执行速查卡全部 SPL，0 报错（REST `/services/search/jobs` 逐条跑，status=done 且无 error） |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「SPL 首搜」。请给我约 60 行：12 条面向 access_combined 日志的 SPL 速查卡（时间范围/fields/table/rename/sort/head/dedup/eval 计算字段/where 过滤，每条带中文注释），加一个 Bash 验收脚本：经 REST API 逐条提交搜索、断言全部完成无报错。只输出代码。`

**完成日期**：2026-11-15
**踩坑记录**：①pipefail 下用 grep 过滤命令输出，无匹配时退出码 1 会静默中止脚本（透传给 sed 才对）；②`round()` 取整后再 where 过滤会失真（4KB→0.00MB 全被筛掉），过滤用原始量纲；③中文字段名 eval 实测可用（`eval 状态=if(...)`）；④0 行 ≠ 报错——只有 messages 里 ERROR/FATAL 才 FAIL。全部实证于 `splunk/03_spl_basics/`（14/14 条 0 报错，重跑实测 3.5s）

---

## 🗂️ 第二阶段：SPL 分析与知识对象（项目 4-6）

> **目标**：从"能搜"到"会算"——统计管道、字段工程、数据富化三板斧

### [x] 项目 4：统计管道——stats/timechart/top 回答业务三问

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~80 行 |
| **核心知识点** | stats 聚合（count/dc/avg/percent）、timechart 分桶、top/rare、bin/span、eval 条件聚合 |
| **核心三问** | 每小时访问量趋势？Top 10 访问来源？404 占比随时间变化？ |
| **前置** | 项目 3 |
| **验收标准** | ~~timechart 输出 24 个小时桶~~（实测校准：教程数据跨 7 天整，改为 `timechart span=12h` 输出 15 桶且全部非空）；`stats` 算出的 404 占比与纯 Python 独立解析对照误差 ≤ 1%（实测 1.7454% vs 1.7454%，零偏差）；top clientip 输出 10 行且 percent 列合计 ≤ 100 |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「统计管道业务三问」。请给我约 80 行：三个业务问题各自的 SPL（timechart 小时桶趋势/top clientip/404 占比时序，每个含 2 种写法对照）、以及一个 Python 对照脚本：把 access 日志按同口径用纯 Python 统计一遍，输出两口径误差断言 ≤ 1%。只输出代码。`

**完成日期**：2026-11-15
**踩坑记录**：①清单"24 小时桶"假设不成立——教程数据实跨 7 天整（39532 条 access 事件），断言按实测校准为 12h×15 桶；②`source .env` 不 export，python 子进程 KeyError（`set -a` 导出）；③时区口径：Splunk 容器按 UTC 解析时间戳，Python 端必须同样挂 UTC，否则分桶错位全线超差；④dataflow 图 `straight` 路由产生斜线违反正交箭头检查，fork 用 bottom/top-channel 路由。双口径对照 39532 行 0 跳过、四项全过（`splunk/04_spl_stats/`）

---

### [x] 项目 5：字段工程——rex、抽取器与 props.conf 持久化

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | rex 内联提取、UI Field Extractor 交互式抽取、props.conf/transforms.conf 的 REPORT 持久抽取、EXTRACT- 命名规则、字段别名 |
| **前置** | 项目 3 |
| **验收标准** | 抽样 20 条原始日志，rex 表达式对每条 `_raw` 执行字段提取，正确率 ≥ 19/20；props.conf REPORT 定义的本地 sourcetype 在搜索时字段自动出现（不写 rex） |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「字段工程」。请给我约 120 行：access_combined 日志的 rex 速查（提取 clientip/method/status/bytes/uri/REFERER/UA）+ props.conf/transforms.conf 完整配置（REPORT 持久抽取，目录路径按 Docker 容器 /opt/splunk/etc）+ Python 抽样验证脚本（20 条日志逐条断言字段提取正确率 ≥ 19/20）。只输出代码。`

**完成日期**：2026-11-15
**踩坑记录**：①oneshot 后检索可见性异步收敛——count 查到 20 但紧接着的 table 只回 1 行，轮询必须打在**目标查询本身**；②props/transforms 改完必须 restart 才生效（配置只在启动时读）；③正则别锚行尾 `$`（_raw 尾部还有响应时间数字，锚死全漏）；④docker cp 后默认 exec 用户(999)删不了 splunk 属主文件（`-u root`）；⑤REPORT 是搜索时提取——改配置后旧事件也立即出新字段。全部实证于 `splunk/05_spl_fields/`（rex 20/20 对照内置 + REPORT 两断言 20/20）

---

### [x] 项目 6：lookup 数据富化——把字典接进日志

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~100 行 |
| **核心知识点** | lookup 定义与匹配字段、inputlookup/outputlookup、KV Store 概念、lookup vs join 的性能与语义差异 |
| **技术栈** | 3 张自建 CSV：HTTP 状态码语义表（≥ 30 行）/ UA 设备分类表 / 服务器资产映射表 |
| **前置** | 项目 5 |
| **验收标准** | 富化搜索后 `status_desc` 的 null 率 ≤ 1%（未知状态码除外，需断言列出）；`inputlookup` 各表行数与 CSV 文件行数一致；同一富化用 join 写法与 lookup 写法跑时对照（lookup 快 ≥ 2 倍，记录进 README） |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「lookup 数据富化」。请给我约 100 行：3 张 CSV 字典（状态码语义/UA 分类/资产映射）+ transforms.conf lookup 定义 + 富化搜索 SPL（含 null 率断言查询）+ lookup 与 join 同题对照 SPL 与计时脚本。只输出代码。`

**完成日期**：2026-11-15
**踩坑记录**：①`| index=...` 是非法 SPL（index 是 search 词不是生成型命令），管道开头必须 `index=` 起头；②system 级 lookup 定义只从 system/lookups/ 解析文件，REST 的 outputlookup 写进 apps/search/lookups（应用上下文）——字典本地生成+docker cp 才落对位；③REST 不补隐式 search **连子搜索也覆盖**，join 的 [] 里必须写 `[search index=...]`；④新 lookup 文件异步生效（docker cp 后立查报错，轮询重试）；⑤WILDCARD 行序即优先级（Chrome 行必须在 Safari 行前）。全部实证于 `splunk/06_spl_lookup/`（四断言全绿 + join 0.49s vs lookup 0.22s = 2.2x）

---

## 🗂️ 第三阶段：真实数据接入（项目 7-9）

> **目标**：教程数据之外——HEC 实时流、UF 文件采集、自定义解析三条真实通道全打通

### [x] 项目 7：HEC 实时接入——JSON 事件管道

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | HTTP Event Collector 开启与 token 管理、/services/collector 事件协议、ack 确认机制、批量发送与索引路由（index 参数） |
| **技术栈** | Python 产生器（模拟 web 访问 JSON 事件）+ curl/requests |
| **前置** | 项目 1 |
| **验收标准** | `curl` 单条事件经 ack 接口确认入库；产生器发 1 万条 → 30 秒内完成发送且 `index=hec_demo \| stats count` = 10000（差额为 0）；`_time` 用事件时间而非接收时间（时间字段对照断言） |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「HEC 实时接入」。请给我约 150 行：HEC token 创建步骤 + Python 产生器（每条事件含事件时间戳/路径/状态码/延迟，JSON 带明确定义的 sourcetype）+ 批量发送脚本（1 万条，含 ack 确认与失败重试）+ 验收脚本（入库数=发送数、时间字段对照）。只输出代码。`

**完成日期**：2026-11-16
**踩坑记录**：①HEC intake 与 indexing 解耦——目标索引不存在时 code=0 且 ack 照给，事件却静默丢弃（实测入库 0 条），先建索引再发事件+搜索对账背书；②ack 异步语义：POST 后立即查 false，~5s 翻 true（轮询）；响应形态是 {ackId: bool} 对象非文档示例的数组；③ack 模式强制 URL 带 ?channel=<hex>；④`stats max(_indextime-_time)` 非法——先 eval 再 stats；⑤对账混入 ack 演示事件（10002≠10000），用 path!=/ack-demo 排除。全部实证于 `splunk/07_spl_hec/`（1 万条 0.13s 发完、差额 0）

---

### [x] 项目 8：Universal Forwarder 采集链——文件监控到索引

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | UF 容器化部署、outputs.conf 指向索引器 9997（TLS）、inputs.conf monitor 段、UF vs 直接监控输入的差异、forwardedindex 过滤 |
| **技术栈** | splunk/universalforwarder（linux/amd64 模拟）+ 挂载目录真实日志 |
| **前置** | 项目 1 |
| **⚠️ 风险** | UF 镜像同为 amd64 模拟（开工探活：`docker pull --platform linux/amd64 splunk/universalforwarder:9.4`）；9997 走自签 TLS；fallback：若 UF 容器异常，降级为索引器本地 monitor 输入（学习目标不变，UF 侧知识点标注跳过原因） |
| **验收标准** | 挂载目录写入 100 行日志（可复用 labs/16-19 的 CI 作业日志样本）→ 2 分钟内 `index=uf_demo \| stats count` ≥ 100；UF 容器日志显示 9997 连接建立（tcpin 状态查询确认）；断网 UF 容器 30 秒再恢复，期间产生的日志不丢（轮转续传断言） |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「Universal Forwarder 采集链」。请给我约 120 行：UF 容器 compose（amd64、挂载日志目录）+ UF 侧 inputs.conf/outputs.conf（9997 TLS 指向索引器）+ 索引器侧接收配置 + 100 行日志写入脚本 + 断言脚本（2 分钟内入库、tcpin 连接、断网续传不丢）。只输出代码。`

**完成日期**：2026-11-16
**踩坑记录**：①UF 镜像 amd64 探活通过（9.4 直连拉取）但 SPLUNK_HOME=/opt/splunkforwarder——docker cp 路径写 /opt/splunk 全无效；②UF 容器内 splunk status 要 -u root（默认 exec 用户 chown 失败）；③目标索引 uf_demo 不存在时转发静默丢弃（lab 07 同款教训在 UF 通道重现）；④引导完成标志=entrypoint 日志 "Ansible playbook complete"（实测约 10 分钟）。全部实证于 `splunk/08_spl_uf/`（100 行 10s 入库 + 断网续传 0 丢失）

---

### [x] 项目 9：自定义 sourcetype——多行栈与结构化解析

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~130 行 |
| **核心知识点** | props.conf 时间解析（TIME_PREFIX/TIME_FORMAT/MAX_TIMESTAMP_LOOKAHEAD）、多行合并（SHOULD_LINEMERGE/BREAK_ONLY_BEFORE）、INDEXED_EXTRACTIONS=CSV 结构化、transform 重命名 |
| **技术栈** | Python 多行异常栈日志产生器 + CSV 结构化样本 |
| **前置** | 项目 5、7 |
| **验收标准** | 多行栈：100 条含异常栈的事件入库后，`index=parse_demo \| stats count` = 100（不丢不并，源文件行数 ≠ 事件数的差异记录进 README）；`_time` 与事件内时间戳一致（抽样 10 条对照全过）；CSV：INDEXED_EXTRACTIONS 后字段直接可查且行数对账一致 |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「自定义 sourcetype 解析」。请给我约 130 行：多行异常栈日志产生器（100 条，事件内嵌时间戳）+ CSV 样本 + 两套 props.conf（多行合并版/INDEXED_EXTRACTIONS 版，含逐行注释）+ 验收脚本（事件数对账、_time 对照、字段抽查 10/10）。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第四阶段：可视化与告警闭环（项目 10-12）

> **目标**：分析成果交付出去——仪表盘有人看、告警真的送达、故障演练闭环

### [x] 项目 10：运维仪表盘——真实数据 4 图盘

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | Dashboard Studio JSON 结构、base search 复用、token 传参、定时刷新、图表选型（时序/环图/单值/表） |
| **产出模块** | `splunk/10_splunk_dashboard/dashboard.json` + 验收脚本 |
| **核心四图** | 服务 QPS 时序、错误率曲线、状态码分布环图、最新错误日志样例表 |
| **前置** | 项目 7、8 |
| **验收标准** | 4 个 panel 的 base search 经 REST 执行各返回行数 > 0；dashboard.json 入库 git；`autoRefresh` 生效（页面间隔刷新配置存在） |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「运维仪表盘」。请给我约 150 行：Dashboard Studio 完整 dashboard.json（QPS 时序/错误率曲线/状态码环图/错误样例表 4 panel，共用 base search，30 秒自动刷新）+ REST 验收脚本（4 个搜索逐条断言行数 > 0）。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 11：告警引擎——调度搜索到 webhook 送达

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | saved search 调度（cron 表达式）、告警触发条件、webhook 告警 action、告警历史与触发记录、Digest vs Realtime 调度 |
| **技术栈** | Splunk saved search + Python webhook 接收器（复用 labs/26 的接收器模式，不重复教） |
| **前置** | 项目 7 |
| **⚠️ 风险** | 告警调度是 Enterprise 专属——**必须在 60 天试用窗口内完成**（清单 6 周排期，窗口够用）；fallback：试用过期后用系统 cron 调 REST `/services/search/jobs` 定时触发搜索模拟，调度语义标注降级 |
| **验收标准** | 手动 "Run once" 触发告警 → webhook 接收器日志收到 payload 且含 `results` 与 `search_name` 字段；连续 3 次 cron 调度触发时间间隔与 cron 表达式一致（接收器时间戳断言，误差 ≤ 5 秒） |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「告警引擎」。请给我约 120 行：saved search conf（错误率告警，cron 每 5 分钟，webhook action 指向本机接收器）+ Python webhook 接收器（记录 payload 与到达时间）+ 验收脚本（Run once 触发断言 payload 字段、3 次调度间隔断言）。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 🏁 项目 12：终极串联——demo-web 服务的观测闭环

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | 双通道接入对账（HEC 直报 + UF 文件采集）、仪表盘消费真实流、服务下线告警、故障演练与恢复验证、观测闭环方法论 |
| **产出模块** | `splunk/12_splunk_full_loop/`（demo-web 服务 + 全部配置 + 演练记录） |
| **载体** | Python FastAPI demo-web：每次请求 HEC 直报一条 JSON + 写文件日志一行（UF 采集）→ 汇入同一索引 |
| **前置** | 项目 7、8、10、11 |
| **验收标准** | 对账：产生 N 请求后 HEC 通道事件数 + UF 通道事件数与请求日志对账一致（差额 0）；演练：`kill` demo-web → **服务下线告警 5 分钟内送达 webhook 接收器**；重启服务 → 仪表盘曲线恢复且对账继续为 0；演练全过程（时间点/告警到达时刻）记录进 README |

**🤖 开始提示词**：
> `我要开始 Splunk 项目「观测闭环终极串联」。请给我约 200 行：FastAPI demo-web（每请求 HEC 直报 + 写文件日志）+ compose 全家桶（splunk/uf/demo-web）+ 仪表盘与两条告警（错误率/服务下线）+ 演练脚本（kill → 等告警送达 → 重启 → 对账断言全程自动化）。只输出代码。`

**完成日期**：2026-11-19
**踩坑记录**：①双通道对账基准用文件行数（重启演练后流量翻倍，"合计=请求数"必失败）；②demo-web 事件时间=当前时钟，service_down 用 dispatch.earliest_time=-3m + count=0；③bootstrap 空窗期索引为空会误报下线（按 arrived_epoch>kill 过滤）；④应用包 docker cp 目录语义嵌套破坏结构（逐文件精确拷贝）；⑤索引 DELETE 物理清理异步——重建后轮询归零才放行。全链实证于 `splunk/12_spl_full_loop/`（对账 0 差额两轮 + kill 后 54s 送达 + 重启恢复）

---

## 📅 周计划

| 周次 | 内容 | 项目数 |
|:---|:---|:---:|
| **第 1 周** | 项目 1-2（部署与教程数据入库） | 2 |
| **第 2 周** | 项目 3-4（SPL 首搜与统计管道） | 2 |
| **第 3 周** | 项目 5-6（字段工程与 lookup 富化） | 2 |
| **第 4 周** | 项目 7-8（HEC 与 UF 双通道接入） | 2 |
| **第 5 周** | 项目 9-10（自定义解析与仪表盘） | 2 |
| **第 6 周** | 项目 11-12（告警与 🏁 观测闭环） | 2 |

## 🏆 里程碑

- [x] **完成项目 1-3** → Splunk 起手使用者：部署、入库、搜索一条龙（2026-11-15 达成）
- [x] **完成项目 4-6** → SPL 数据分析师：统计/字段/富化三板斧（2026-11-15 达成）
- [ ] **完成项目 7-9** → 数据接入工程师：HEC/UF/自定义解析三通道
- [x] **完成项目 10-12** → 🏁 观测闭环交付者：仪表盘+告警+故障演练全链路（2026-11-19 达成）

## 📝 每日日志

| 日期 | 项目 | 耗时 | 收获 | 踩坑 |
|:---|:---|:---:|:---|:---|
| 2026-11-15 | 项目 1 | ~1.5h | 部署+两卷持久化实证；REST 搜索正确姿势；license features 里 Trial 与 Free 的告警能力差异 | `:ro` 挂载炸 chown / exec 用户身份 / search 显式前缀 / oneshot 检索延迟 |
| 2026-11-15 | 项目 2 | ~2.5h | 四元组逐文件标注入库；tstats 元数据查询；官方教程数据集真实结构（8 文件/4 主机/3 类日志） | WAF UA 403 / CDN 字节数漂移 / oneshot 参数名 / 生成型与转换型命令前缀规则 |
| 2026-11-15 | 项目 3 | ~1.5h | 速查卡即契约的自验收模式；eval/where 分工；实验间产物衔接（03 自动补灌 02 数据） | pipefail+grep 静默中止 / round 后过滤失真 / 中文列名实测可用 |
| 2026-11-15 | 项目 4 | ~2h | 双口径对照方法论（零共享代码/UTC 对齐/跳过行体检）；同题两写法等价性实证；数据跨度先量再定断言 | "24 小时桶"假设翻车 / env 不导出 / 时区口径 / 正交路由 |
| 2026-11-15 | 项目 5 | ~2h | rex 与 REPORT 两条提取路；两层参照验证（出厂解析+Python 独立）；搜索时提取语义 | 可见性异步收敛 / restart 才生效 / 锚行尾漏配 / exec 用户权限 |
| 2026-11-15 | 项目 6 | ~2.5h | 三种匹配形态（精确/WILDCARD/资产）；行序优先级；join vs lookup 机理对照（2.2x） | "| index=" 非法 / lookup 落位（应用上下文） / 子搜索也要 search 前缀 / 异步生效 |
| 2026-11-16 | 项目 7 | ~2.5h | HEC 协议全形态（token/channel/ackId）；ack 异步翻转语义；_time 归属实证（事件时间 vs 接收时刻差 5400s） | 索引静默丢弃（intake≠indexing）/ ack 对象形态 / stats 算术非法 / 对账混入演示事件 |
| 2026-11-16 | 项目 8 | ~2.5h | UF 采集链全通（TLS 9997）；断网续传机理（fishbucket 偏移量）；UF 目录真相 | /opt/splunkforwarder 路径 / -u root / 目标索引静默丢弃 / 引导 10 分钟 |
| 2026-11-16 | 项目 9 | ~2.5h | 多行切分对账（488 行→100 事件）；INDEXED_EXTRACTIONS 索引时字段；双轨时机差异 | BREAK_ONLY_BEFORE 锚行首 / 先部署后入库 / prod.json 落盘 / _time 取首行 |
| 2026-11-18 | 项目 10 | ~1.5h | Dashboard Studio 三层结构；JSON 即契约的 panel 验收；refresh 配置位置 | 教程时间窗错位 / refresh 在 dataSource / 空桶位实测不存在 |
| 2026-11-19 | 项目 11 | ~2.5h | 告警链路全通（调度→动作→送达）；应用包与命名空间；间隔断言方法（120s/120s） | system/local 不执行 / [webhook] 遮蔽内置 / dispatch 不触发动作 / ls glob 静默退出 |
| 2026-11-19 | 项目 12 | ~3h | 双通道不变量对账；服务下线告警 54s 送达；kill/重启演练自动化 | 对账基准=文件行数 / bootstrap 空窗误报 / docker cp 目录嵌套 / 索引清理异步 |
| | | | | |

## 🔧 环境配置

```bash
# 0. 已就绪（2026-11-15 实测）
# - OrbStack：daemon 已配 daocloud + 1ms 镜像源与代理（labs 全系列共用）
# - python3.13（anaconda3）、curl、git
# - splunk/splunk:9.4 linux/amd64：官方无 arm64（latest/10.0/9.4/9.3 全实测失败）。
#   镜像源拉不动它（1ms 坏层 magic number mismatch / daocloud 白名单拒），
#   必须走 OrbStack 代理直连 Docker Hub——本镜像已拉好并 boot 实测过（9.4.17，~45 秒冷启动）：
docker pull --platform linux/amd64 registry-1.docker.io/splunk/splunk:9.4
docker tag registry-1.docker.io/splunk/splunk:9.4 splunk/splunk:9.4

# 1. 每项目开工前：统一检查
docker image inspect splunk/splunk:9.4 --format '{{.Os}}/{{.Architecture}}'   # 应输出 linux/amd64
docker compose ps && curl -sk -u admin:<密码> https://localhost:8089/services/server/info | grep -o '<s:key name="version">[^<]*' # 探活

# 2. 教程数据（项目 2）
curl -A "Mozilla/5.0" -LO https://docs.splunk.com/images/Tutorial/tutorialdata.zip  # 默认 UA 实测 403

# 3. 试用窗口提醒：从项目 1 起算 60 天，项目 11 告警调度必须在窗口内完成
```

## ⚠️ 与已有清单的关系

| 已有清单/实验 | 关系 |
|:---|:---|
| devops.md lab 26（Prometheus/Grafana/Alertmanager） | metrics 一柱以 lab 26 为准，本清单不碰 Prometheus；项目 11 告警复用其 webhook 接收器模式（不重复教接收器），专讲 Splunk 调度告警语法 |
| devops.md lab 27（Loki+Promtail） | 集中日志概念已入门；本清单专注 Splunk 特有体系（sourcetype/props.conf/UF），Loki 不再涉及 |
| devops.md labs 16-19（Jenkins/Gitea Actions/Woodpecker） | 项目 8 可选复用 CI 作业日志作真实数据源，不教 CI 本身 |
| devsecops.md（安全线，30 项目） | 本清单是 DevOps 观测线，不含 SIEM 检测规则/SOC 流程；安全视角（审计索引/检测规则）留给该线后续 Splunk 进阶 |
| terraform.md / cicd.md / cicd-semi.md / cloudify.md / pulumi.md | 无直接交集 |

## 📚 能力覆盖速查表（2026-11-15 实测）

| 能力/依赖 | 计划 | 实测结论 |
|:---|:---|:---|
| splunk/splunk linux/arm64 | Docker 原生 | ❌ 不存在：latest/10.0/10.0.0/9.4/9.4.3/9.3 六个 tag 全部 `no matching manifest for linux/arm64` |
| splunk/splunk:9.4 linux/amd64 | Rosetta 模拟 | ✅ **全链路实测通过**：经 OrbStack 代理直连 Docker Hub 拉取成功（镜像源不可用：1ms 坏层/daocloud 白名单），boot 后 REST 返回 9.4.17、Web 8000 正常，冷启动 ~45 秒 |
| 国内镜像源拉 Splunk 大镜像 | 1ms / daocloud | ❌ 1ms 反复 `magic number mismatch`（坏层）；daocloud 提示镜像不在白名单——此类大镜像一律直连 |
| OrbStack 资源 | amd64 容器 | ✅ 64GB RAM / 18 核，模拟跑 Splunk 单机绰绰有余 |
| tutorialdata.zip | curl 下载 | ⚠️ 默认 UA 403；浏览器 UA 200（1.9MB） |
| 告警调度 / 认证 / 多索引 | Enterprise 全功能 | ⚠️ 依赖 60 天试用窗口——清单按 6 周排期，窗口内完成；过期降级 Free（500MB/天，无告警调度），fallback 见项目 11 |
| splunk/universalforwarder amd64 | UF 容器 | ✅ 实测通过（2026-11-16）：9.4 镜像直连拉取成功、容器引导 ~10 分钟、9997 TLS 连接与采集全链路正常 |

## 📚 来源

- [Splunk 官方 Docker 镜像仓库（splunk/docker-splunk）](https://github.com/splunk/docker-splunk)
- [Splunk Search Tutorial（教程数据与导入步骤）](https://docs.splunk.com/Documentation/Splunk/latest/SearchTutorial/WelcomeTotheSearchTutorial)
- [tutorialdata.zip 下载地址](https://docs.splunk.com/images/Tutorial/tutorialdata.zip)
- [Splunk Free 与 Enterprise 许可差异](https://docs.splunk.com/Documentation/Splunk/latest/Admin/MoreaboutSplunkFree)
