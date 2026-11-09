# 08 · pg backend 真锁并发：两个人同时 apply，数据库说了算

> 把 Terraform（用声明式配置文件创建和管理基础设施的开源工具）的 state 后端（存放 terraform.tfstate 这份"基础设施账本"的位置）换成 PostgreSQL，在真机上复现状态锁的三个经典时刻：并发被拒、持锁者假死造成的锁卡死、以及真正能解开的强解手段。
>
> 跑完 `./pg_backend_lock.sh all`（约 3 分钟）得到一份 9 条断言全过的记录。

## Background

没有远端 state 时，terraform.tfstate 是每人机器上的一份本地文件。两个人各自 apply（Terraform 的执行命令：按配置真正创建/修改资源）同一份配置：后写的把先写的覆盖掉，引擎却毫不知情——下一个人 plan（只预览将做什么、不改资源的命令）时看到的"现状"已经是错的。

痛点出现在协作与 CI（持续集成服务器：定时或事件触发、自动执行构建与部署的机器人）交接处。

工程师 A 的 apply 还在进行（要几分钟），CI 的定时任务同时 apply。

两边都按旧账本和各自计划改基础设施：最终 state 留下一份从未被完整执行的混合结果。

远端后端因此而来：state 只存一份，且写入前必须先拿到锁。Terraform 内置多种远端后端（S3、PostgreSQL、Consul 等）。

本实验选 PostgreSQL——它的锁不是"约定"，而是数据库自带的 advisory lock（咨询锁：数据库会话持有的一把占用标记，同一时刻只发给一个会话，会话结束自动回收）。

## What

state 锁是 apply 开始到结束期间在后端上持有的一把互斥标记，保证同一份 state 同时只有一个写入者。拿到锁的 apply 才允许执行；拿不到的直接失败，这就是"两个人同时 apply"的答案。

可以把 pg 的 advisory lock 想象成公共储物柜的钥匙：只有一把，谁拿着柜门就锁着。但和实体钥匙不同的是归还机制——持锁进程正常结束或连接断开，数据库当场收回锁；进程只是"假死"（连接还在），锁就一直被占着。

三种结局对应三个演示场景，时序如下（绿=放行、红=拒绝；看得见的锁都在 `pg_locks` 表里）：

![pg backend 状态锁时序](images/pg-lock.sequence.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/terraform/08_pg_backend_lock/images/pg-lock.sequence.html)
> （或本地打开 [`images/pg-lock.sequence.html`](images/pg-lock.sequence.html)）。

## When to Use

| 场景 | 用什么 |
|:---|:---|
| 团队共享一份 state，成员与本机 CI 都会 apply | pg / S3 类远端后端 + 锁，必选 |
| apply 窗口长（数据库迁移、实例启动），期间他人可能误操作 | 锁 + 告警：被拒的报错会即时暴露冲突 |
| 单人本地实验，无协作 | local 后端足够，锁是负担不是收益 |

同类后端怎么选：

- **local**：无锁，仅单人。
- **pg**：锁由数据库会话保证，进程死亡后锁自动回收。
- **S3+DynamoDB**（传统）：锁是两张表里的数据，持有者死亡后锁滞留，必须手动 `terraform force-unlock`。
- **S3 use_lockfile**（TF 1.10+）：用 S3 对象当锁文件，介于两者之间。

选 pg 的核心理由只有一条：锁的互斥由数据库亲自保证，没有"锁数据没人清"这类次生事故。

## Quick Start

前置条件：

- Terraform ≥ 1.6
- Docker（作者在 macOS 的 OrbStack 上实测，任何能跑 `docker run` 的环境均可）
- 宿主 15432 端口空闲，且本机有 postgres:16-alpine 镜像
- provider（Terraform 用来跟具体平台对话的插件，本实验用到 Docker 和 time 两个）经仓库内置镜像源安装：脚本自动 source `scripts/tfrc.sh`，不访问外网

```bash
./pg_backend_lock.sh all        # 五步一条龙：up → init → demo → verify → clean
```

demo 与 verify 阶段的真实输出（节选，`......` 为省略，ANSI 颜色码已略去）：

```text
=====> [demo] 场景一【并发撞锁】：A 持锁窗口内 B 强行 apply
......
        A 已持锁（后台 apply，日志 applyA.log），pg_locks 里 advisory granted=1
......
        [ok]   B 被拦且报错含 'Error acquiring the state lock'
        锁信息已随报错吐出：Lock ID = b40e6915-b80e-4f8d-ee6f-a04717090619
......
=====> [demo] 场景三【强解】：先试 terraform force-unlock，再上 DBA 手段
        | Terraform state has been successfully unlocked!
......
        ↑ force-unlock 在 pg 后端的真实行为（退出码 0）——报成功但锁不动，README 讨论
        [ok]   pg_terminate_backend 掐断持有者连接 → 锁归零（granted=0）
......
=====> [verify] 终态断言：plan 干净 / 资源在 state / state 落库
        [ok]   terraform plan → No changes（终态收敛）
......
        断言汇总：PASS=9 FAIL=0
```

分步跑也行（每步可单独执行）：

- `up`：起 postgres:16-alpine，健康等待
- `init`：初始化 pg backend，自带三次握手重试
- `demo`：三场景 + 5 条断言
- `verify`：终态 4 条断言
- `clean`：destroy + 清容器 + 零残留断言

诚实预期：init 偶发一次 `Error: EOF` 后自动重试通过；demo 全程约 2 分钟，其中 A 的持锁窗口人为拉长到 45 秒。

## How It Works

后端配置只有一处：`configs/versions.tf` 里 `backend "pg"` 指向 `localhost:15432`。`terraform init` 时会在库里建 schema `terraform_remote_state`（state 正文存在其 `states` 表）。

apply 开始时对 state 名字取哈希，执行 `pg_try_advisory_lock(哈希值)`——你在输出里看到的 `granted=1`，就是这次取锁在 pg_locks（实时系统视图）里留下的记录；锁本身不持久保存，落库的是 state 正文。

场景一的拦截点：B 的 apply 还没碰到任何资源，卡在取锁这步。报错把锁的"身份证"一并吐出（`Lock Info: ID: ...`），脚本从中提取 Lock ID 供场景三使用——被拒的报错本身就是排障入口，不用去翻日志。

场景二的关键是 SIGSTOP（冻结进程但不杀、不断连接的信号）。A 被冻结后：进程在、TCP 连接在、数据库视角下锁持有者活得好好的——于是 C 同样被拒。这就是"锁卡死"事故的原型：持有者没死，只是永远不再动了。

场景三先试文档主推的 `terraform force-unlock -force <ID>`：实测退出码 0、报成功，但随后 `pg_locks` 里 granted 仍是 1——advisory lock 是会话级的，别的会话无权解锁，这次"成功"没有动锁。

真正生效的是 `pg_terminate_backend(pid)`：从库里直接掐断持有者的连接，连接断，锁当场回收。恢复后 D 正常 apply，plan 最终 `No changes`。

A 被击毙还有一个副作用值得看清：它可能死在 state 持久化之前——引擎里留下了资源，state 却不知道（孤儿）。演示里直接清掉孤儿让 D 从干净态收敛；生产里的正规做法是用 import 把存量资源收编进 state（本系列项目 10 详谈）。

## Pitfalls & Q&A

- **force-unlock 在 pg 后端假成功**：退出码 0、报 unlocked，锁纹丝不动（granted 仍 1）。原因：advisory lock 会话级，force-unlock 用自己的会话去解别人的锁。解法：`pg_terminate_backend` 掐持有者连接；S3+DynamoDB 后端上 force-unlock 才是真解。
- **杀 CLI 不杀 provider，apply 会"诈尸"**：provider 插件（terraform 拉起的独立子进程）有自己的生命周期。实测 kill -9 CLI 后 40 分钟，引擎恢复时 provider 把半途的容器创建了出来。解法：杀 apply 必须连子进程一起（脚本 `kill_A` 先 `pkill -P` 再杀主进程）。
- **OrbStack 给新容器注入日志默认值导致永久替换**：state 里出现 `log_opts = {"max-file"="5", "max-size"="20m"}`，plan 计划值是 null，ForceNew（provider 在属性上标记的"新旧值不同就必须重建整个资源"规则）判定不同 → 每次计划都要求重建，永不收敛。
- **OrbStack 替换循环的解法**：本实验改用 `docker_image` + `time_sleep`（零替换噪音）；确需容器时显式声明与引擎一致的 log_opts。

- **pg_isready 通过 ≠ 后端可握手**：postgres 刚就绪有短暂预热窗口，init 偶发 `Error: EOF`。解法：脚本自动重试三次，两次以内必稳（实测）。
- **bash 3.2 的全角标点陷阱**：`$VAR）` 会被老 bash 把多字节字符吃进变量名，报 unbound variable。解法：中文标点紧邻的变量一律写 `${VAR}`。

Q：为什么场景三不演示"杀掉持锁者后再 force-unlock"？A：SIGKILL 下连接直接断，数据库自动回收锁，根本轮不到 force-unlock——这正是 pg 对比 S3+DynamoDB 的核心优势（那边锁会真滞留），所以演示按"假死滞留"设计。

Q：A 半途被杀留下的孤儿，除了清掉还能怎么处理？A：import 收编进 state 后统一管理；区分"该清"还是"该收编"的依据是资源是否仍被业务使用，这条判断链在项目 10、11 展开成完整闭环。
