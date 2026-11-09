# 09 · S3 backend 真锁：锁是桶里的一个对象

> 把 Terraform（用声明式配置文件创建和管理基础设施的开源工具）的 state 后端（存放 state 文件的远端位置；state 记录 Terraform 已创建了哪些资源）换成 S3 兼容对象存储（自家 ObjStor），启用 TF 1.10+ 的 use_lockfile 原生锁。
>
> 在真机上走完锁对象的一生：被创建、被 cat、杀死持锁者后依然存在、被 force-unlock 删除、进程重启后 state 完好。跑完 `./s3_backend_lock.sh all`（约 3 分钟）得到 11 条断言全过的记录。

## Background

项目 08 的 PostgreSQL 后端里，锁是数据库会话（数据库视角下的一次连接）的附属品：持锁进程一死、连接一断，锁自动回收。这套行为的前提是"锁由一个常驻服务实时保管"。

S3 系后端（S3、自有 S3 兼容存储）没有这个前提。TF 1.10 之前，锁要靠一张 DynamoDB 表来记账；1.10 起 use_lockfile 把账本简化成桶里的一个普通对象（`<key>.tflock`）。锁从"会话状态"降格成"一行数据"——而数据不会因为它的创建者消失而消失。

这个差异不是细节：持有者被杀后，pg 的锁自动回收，S3 的锁留在桶里把所有人挡在门外。谁对哪种行为有预期，决定了事故现场该跑哪条命令。本实验把两种结局都亲手触发一遍。

## What

use_lockfile 是 S3 后端的一个开关：开启后 Terraform 取锁 = 往桶里 PUT 一个 `<key>.tflock` 对象（内容是持锁者信息 JSON），释放 = 删除它，互斥依据就是这个对象存在与否。

可以把 tflock 想象成公共储物柜里的一张"占用卡"（08 的 pg 锁是柜门上的电子锁，人走自动开）。但类比到这里要失效了：占用卡是写进桶里的纸——写卡的人被带走，卡还留在桶里，除非有人来撕。这就是"锁是数据"的含义。

锁对象的一生（撞锁、滞留、强解、进程重启后的"远程性"——数据在存储里、不在进程里，重启服务数据无损）：

![S3 backend 状态锁时序](images/s3-lock.sequence.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/terraform/09_s3_backend_lock/images/s3-lock.sequence.html)
> （或本地打开 [`images/s3-lock.sequence.html`](images/s3-lock.sequence.html)）。

## When to Use

| 场景 | 用什么 |
|:---|:---|
| 团队与 CI（持续集成服务器：定时或事件触发、自动执行构建与部署的机器人）共享 state，且已有 S3 兼容存储（云桶或自建） | S3 后端 + use_lockfile |
| 需要跨云账号/跨团队共享 state，pg 实例反而不方便暴露 | S3 后端的桶策略比数据库账号更好管 |
| 已有稳定 pg 实例，且在意"持有者死亡锁自动回收" | pg 后端（项目 08） |

同类后端一行对照：**local** 无锁；**pg** 锁随连接生灭；**S3+DynamoDB**（TF 1.10 前的主流）锁在两张表里，行为与 use_lockfile 同为"数据型滞留"，但要多维护一张 DynamoDB 表。

TF 1.10+ 之后 DynamoDB 不再是必选件：**S3 use_lockfile** 用一个桶对象完成同样的事，少一个组件。

## Quick Start

前置条件：

- Terraform ≥ 1.11（use_lockfile 原生锁需 1.10+；配置使用的 endpoints.s3 新写法需 1.11+）
- python3（脚本内置迷你 S3 客户端 scripts/s3_client.py，纯标准库、无第三方依赖）
- 本机有 ObjStor 二进制（仓库同级 `../../objstor/target/release/objstor`，缺失时脚本会提示构建）
- 宿主 9200 端口：脚本会接管该端口上的遗留 ObjStor 实例（含 labs/03 的），跑完自动关闭
- provider（Docker、time 两个）经仓库内置镜像源安装：脚本自动 source `scripts/tfrc.sh`，不访问外网

```bash
./s3_backend_lock.sh all        # 五步一条龙：up → init → demo → verify → clean
```

demo 与 verify 阶段的真实输出（节选，`......` 为省略，ANSI 颜色码已略去）：

```text
=====> [demo] 场景一【撞锁】：A 持锁窗口内 B 强行 apply
        锁对象 lab09/terraform.tfstate.tflock 已在桶里（HTTP 200）——锁是数据，cat 得出来：
         {'ID': 'cf7cd402-e3ed-d1cf-5755-0d45ba3ad6de', 'Operation': 'OperationTypeApply', 'Who': 'hyhit@Mac'}
......
        [ok]   B 被拦且报错含 'Error acquiring the state lock'
......
=====> [demo] 场景二【滞留】：SIGKILL A——pg 里连接断锁自动回收，这边呢？
......
        [ok]   持锁者死亡后锁对象仍在桶里（granted 与否无关——锁是数据）
        [ok]   C 照样被拒——这就是 S3 系'锁卡死'事故原型
......
=====> [demo] 场景三【真解】：force-unlock 删掉锁对象（这边它是真解）
        | Terraform state has been successfully unlocked!
......
        force-unlock 退出码 0——对照项目 08 的假成功，看锁对象还在不在：
        [ok]   force-unlock 后锁对象消失（exists=404）——S3 系上它是真解
......
=====> [verify] 重启远程性：杀掉 ObjStor 进程再拉起，state 完好
......
        [ok]   重启后 plan 仍 No changes——数据在对象存储，不在进程里
......
        断言汇总：PASS=11 FAIL=0
```

分步跑也行（每步可单独执行）：

- `up`：起 ObjStor 宿主进程（接管 9200），建桶
- `init`：初始化 S3 backend，自带三次握手重试
- `demo`：锁生命周期三场景 + 6 条断言
- `verify`：终态 + 重启远程性 5 条断言
- `clean`：destroy + 清桶内 lab09 前缀 + 停 ObjStor + 零残留断言

诚实预期：plan（只预览将做什么、不改资源的命令）偶发崩溃会在桶里留下滞留锁（锁是数据，进程死了数据还在），脚本按"发现滞留锁 → force-unlock → 重试"的剧本自愈并打印过程；init 偶发握手失败自动重试三次。

## How It Works

取锁即上传：apply（Terraform 的执行命令：按配置真正创建/修改资源）开始时 Terraform 向桶 PUT `lab09/terraform.tfstate.tflock`，内容是持锁者 JSON（ID/Operation/Who）——输出里 cat 出来的就是它。

后来者取锁前先查对象：存在即拒绝，报错里附带这份 JSON（`Lock Info: ID: ...`），排障入口与项目 08 相同。

释放即删除：apply/plan 正常结束会 DELETE 这个对象；异常退出（被 SIGKILL、崩溃）则没有机会删——对象永续存在，这就是滞留。对照实验：项目 08 里同一出戏演到这一幕，pg 已经把锁收走了。

force-unlock 在两种后端上行为相反：pg 上它用自己的会话去解别人的会话锁（解不动，假成功）；S3 上它直接删桶里的锁对象（真删，`exists` 从 200 变 404）。

你在场景三输出里看到的两次对照，就是"锁是会话"与"锁是数据"的分界线。

plan 也会留滞留锁：plan 与 apply 走同一套锁协议，中途崩溃同样把 tflock 留在桶里。脚本 verify 阶段内置了自愈剧本——撞锁报错里取 Lock ID，`force-unlock` 强解后重试一次（持有者已死，强解无害）。

重启远程性：ObjStor 进程只是数据的仆人。杀掉进程再拉起（数据目录不动），`plan` 照样读出完整 state 并输出 `No changes`。另外 state 正文的写入是对象存储的单对象原子 PUT——不存在"写一半"的中间态，这点比本地单文件可靠。

## Pitfalls & Q&A

- **重启脚本顺手清了数据目录，"远程性"演示直接翻车**：初版重启复用了"全新启动"函数，它开头 `rm -rf` 数据目录——要证明没丢的数据先被脚本删了。解法：拆成 `prepare`（全新数据）与 `launch`（保留数据）两段，重启只走后者。
- **plan 崩溃留滞留锁，且报错被吞后像"数据丢了"**：verify 的 plan 若 `2>/dev/null` 丢弃 stderr，真实故障（撞滞留锁）不可见，下游断言全挂。解法：完整捕获输出，撞锁报错走"取 Lock ID → force-unlock → 重试"剧本。
- **versions.tf 漏写 required_providers，Terraform 去查不存在的 hashicorp/docker**：资源类型 `docker_image` 的默认命名空间是 hashicorp/docker（并不存在），报错 `Did you intend to use kreuzwerker/docker?`。
- **provider 漏声明的解法**：显式声明 `source = "kreuzwerker/docker"`；time 同理显式 `0.13.1`（镜像源里是 0.13.1，直接联网会装更新版本，与锁定版本漂移）。
- **ObjStor 从进程 CWD 读硬编码配置路径**：`data/config/objstor.json` 是相对路径，启动目录不对就静默新建空配置。解法：cd 进专属数据目录再启动（labs/03 同款坑）。

Q：锁对象能手工删吗？A：能（就是删一个对象），但先确认持有者真的死透——持有者还活着时强删，两个 apply 会对同一份 state 并发写入，比滞留锁糟糕得多。

Q：本实验和项目 08 怎么连着记？A：一句话对照——pg 的锁是会话（人走锁收，force-unlock 假成功），S3 的锁是数据（人走锁留，force-unlock 真解）；把两边对应场景的断言对照着看，后端选型的依据就齐了。
