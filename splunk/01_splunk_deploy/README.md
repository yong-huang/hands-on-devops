# 01 · Splunk Enterprise 单机部署：amd64 镜像在 Apple Silicon 上落地

> 在没有官方 arm64 镜像的限制下，把单机 Splunk Enterprise 部署到 macOS + OrbStack（macOS 上的容器运行环境，Docker Desktop 的替代品），并用一次"重启不丢数据"的断言实证部署可用。读完你能带走：一份可复用的 compose 模板、REST 探活方法、两卷持久化的验证手段，以及四个踩坑记录。

## Background

没有集中检索平台之前，查问题靠 `grep` 一台台机器翻日志。日志散在各处、格式各异，跨机排查一次故障要来回登录多台主机，时间窗口一长日志还被轮转清掉。

集中式日志平台把"数据"与"检索"分离：机器数据先统一入库，再用统一查询语言跨源检索。Splunk 是这类平台中最老牌的商用产品，本仓后续的接入、仪表盘、告警实验都以它为载体。

把 Splunk 装到本机会连撞两堵墙。其一，官方 `splunk/splunk` 镜像至今没有 arm64 版本——`latest`、`10.0`、`9.4`、`9.3` 六个 tag 全部返回 `no matching manifest for linux/arm64`（2026-11-15 实测）。

其二，首次启动是黑盒：哪个目录存索引、重启会不会丢数据，不实测就没有底。本实验把两堵墙一起拆掉。

## What

Splunk Enterprise 是一个把机器数据（日志、指标、追踪）解析成可检索事件的索引平台。检索语言叫 SPL（Search Processing Language，从 `search` 开始、以管道连接处理命令）。

可以把索引（index）想象成数据库的 database——但和数据库不同，"表结构"（字段）不在建表时定义，而在数据进来时自动推断，推断错了再用配置修正。

部署形态只有三层：

| 组件 | 端口 | 作用 |
|:---|:---|:---|
| splunkd | 8089 | 管理进程，REST API 全走它（自签 HTTPS） |
| Splunk Web | 8000 | 浏览器界面（内嵌 nginx，比 splunkd 晚就绪） |
| etc / var 两卷 | - | 配置与索引数据的持久化载体 |

![architecture](images/splunk_deploy.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/splunk/01_splunk_deploy/images/splunk_deploy.html)
> （或本地打开 [`images/splunk_deploy.html`](images/splunk_deploy.html)）。

## When to Use

- **本机学习沙盒**：给后续接入 / 告警实验一个真实 Splunk，功能与生产单机一致
- **小规模真实检索**：个人或小团队 500 MB/天以内的日志检索够用
- **何时不用**：生产环境多节点、高可用、每日 GB 级以上数据——那是索引器集群（indexer cluster）的领域，单机模型装不下；纯收集不检索的场景，Grafana Loki 更省资源

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| 本实验：单机容器（试用版） | 全功能 + 60 天窗口 | 学 SPL / 接入 / 告警全链路 |
| Splunk Cloud | 免运维，但收费且数据出本机 | 零云约束下排除 |
| Grafana Loki | 只索引标签不索引全文，资源省 | 只看日志、预算敏感时 |

## Quick Start

前置：OrbStack 或 Docker Desktop；镜像 `splunk/splunk:9.4`（linux/amd64）。国内镜像源拉不动它（坏层/白名单），直连命令：

```bash
cd labs/31_splunk_deploy
docker pull --platform linux/amd64 registry-1.docker.io/splunk/splunk:9.4
docker tag registry-1.docker.io/splunk/splunk:9.4 splunk/splunk:9.4
cp .env.example .env   # 设置 SPLUNK_PASSWORD（≥8 位且非纯数字，首次启动强校验）
./splunk_deploy.sh up
```

`up` 的真实输出（节选）——Rosetta（Apple 的 x86→ARM 二进制转译层）模拟下冷启动约 65 秒，Web 再晚 10 秒：

```
=====> [up] 启动 Splunk Enterprise（amd64 镜像，Rosetta 模拟）
        等待 splunkd REST 就绪（首次启动，上限 420s）...
        [ok] splunkd 就绪（约 65s）
        等待 Splunk Web 就绪...
        [ok] Web 就绪（HTTP 303，约 10s）
        ✅ Splunk Web: http://localhost:28000 （admin 登录）
```

`info` 观察版本、架构与许可（节选）——`cpu_arch: x86_64` 是"确实在跑 amd64 代码"的直接证据，试用许可明确到日：

```
=====> [info] 版本 / 架构 / 许可证 / 端口
        version : 9.4.17
        cpu_arch: x86_64   os: Linux
        image     : linux/amd64
        license : Splunk Enterprise   Splunk Analytics for Hadoop Download Trial | 到期 2027-01-14 | 剩 59 天
        告警调度可用: True / 定时搜索: True
```

`persist` 灌 5 条标记事件 → 重启容器 → 断言事件仍在（节选）——持久化不是"相信卷"，是数出来的：

```
=====> [persist] oneshot 灌 5 条标记事件 → 重启 → 断言数据仍在
        [ok] oneshot 上传完成（run=run1794718526）
        ✅ 重启前：run=run1794718526 事件数 = 5
        ✅ 重启后：run=run1794718526 事件数 = 5 —— var 卷持久化实证
        ✅ etc 卷持久化：telemetry.conf 重启后仍在
```

`./splunk_deploy.sh down` 销毁容器与两卷，回到实验前状态；只想暂停保留数据用 `stop`。

## How It Works

**amd64-on-arm64 的转译**。compose 里 `platform: linux/amd64` 让 OrbStack 用 Rosetta 2（Apple 的 x86→ARM 二进制转译层）跑 amd64 镜像，缺这行拉取直接报 `no matching manifest`。

代价是性能：实测冷启动约 65 秒（原生 arm64 通常 40 秒内），对学习场景够用。`cpu_arch: x86_64` 来自容器内部视角，它看不到宿主是 ARM——这正是转译完整性的证明。

**两个 named volume（由 Docker 创建并命名、生命周期独立于容器的存储卷）的分工**。`splunk-etc` 挂 `/opt/splunk/etc`（配置、App、本地覆盖配置），`splunk-var` 挂 `/opt/splunk/var`（索引数据，即 `$SPLUNK_DB`）。

重启进程丢的是内存态，落盘的索引在 var 卷里，所以 persist 断言能过。

telemetry.conf 以文件级 bind mount（把宿主机现存文件直接映射进容器，区别于由 Docker 管理的 named volume）叠挂进 etc 卷的 `system/local/` 目录——system/local 是本地覆盖配置目录，优先级高于出厂默认的 `system/default/`。

**persist 的数据流**。四步：`docker cp` 把标记文件送进容器 → `splunk add oneshot` 把整个文件灌成索引事件 → REST `exec_mode=oneshot` 搜索同步返回计数 → `docker compose restart` 后复查计数。

oneshot 是不经 HEC（HTTP Event Collector，JSON 事件入库通道）、不经 Forwarder（Universal Forwarder，装在数据源机器上转发数据的轻量代理）的最轻量入库通道。搜索走 8089 端口，认证用 `admin` + `.env` 里的密码。

**端口表与预告**。28000→8000 是 Web；28089→8089 是管理 REST，本实验全部探活与搜索走它。

28088→8088 预留给 HEC；29997→9997 预留给 Forwarder 接收口。后两个端口现在不通，是后续实验的接线板。

## Pitfalls & Q&A

- **`no matching manifest for linux/arm64`**：官方镜像无 arm64。解法是 compose 写 `platform: linux/amd64`、拉取显式 `--platform linux/amd64`
- **镜像源拉取报 `magic number mismatch`**：1ms/daocloud 对这个大镜像返回损坏层或白名单拒绝。解法是绕开镜像源直连 `registry-1.docker.io`（OrbStack 自带代理转发，TLS 端到端不经过中转）
- **首次启动 ansible（官方镜像入口脚本内置的配置工具，负责初始化 etc 卷）重试 60 次失败**：入口脚本会递归 `chown` 整个 etc 树，telemetry.conf 挂了 `:ro` 后 chown 失败，容器退出（Exited 2）。解法：bind mount 不加 `:ro`
- **REST 搜索报 `Unknown search command 'index'`**：REST 的 `search` 参数不自动补隐式 `search` 命令（Web UI 会补）。解法：search 参数显式以 `search ` 开头
- **oneshot 后立刻搜索计数为 0**：事件落盘到可检索有秒级延迟。解法：轮询等待而非立即断言（本实验 `wait_count` 上限 30 秒）

**Q1：60 天试用到期会怎样？** 自动降级 Splunk Free：每天 500 MB 入库上限、无告警调度（实测许可证 features 列表：试用版含 `Alerting`/`ScheduledAlerts`，Free 版没有）。后续告警实验要排在试用窗口内，或改用系统 cron 调 REST 触发搜索。

**Q2：`stop` 和 `down` 选哪个？** `down -v` 连卷一起删，适合练完清场；`stop` 保留两卷，下次 `up` 直接续用——如果数据还要用（如接着做 SPL 练习），用 `stop`。

**Q3：`cpu_arch: x86_64` 而宿主是 ARM，数据可信吗？** 可信。splunkd 读的是 `/proc/cpuinfo`，Rosetta 转译层把这个虚拟化得很完整——应用程序视角看不到宿主架构。

镜像视角才是真实平台：`docker image inspect` 的 `.Architecture` 显示 amd64。
