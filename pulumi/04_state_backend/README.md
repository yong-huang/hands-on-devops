# 04 · 状态管理：账本搬家——本地 file → MinIO S3 后端

> state（账本）记录着"哪些资源归我管"。它躺在实验目录的 `.pulumi-state/` 里：
> 手滑删目录、换电脑、同事 clone 不下来，账本就没了。本实验把账本整体搬进
> MinIO（一个兼容 Amazon S3 接口的对象存储：S3 是亚马逊的云存储服务，"桶"
> 是其中存放数据的顶层空间）：export → init → import 三步搬完，容器不动、服务不断。
>
> 顺带演练 refresh 漂移对账（漂移 drift：现实与账本不一致，比如有人手工删掉了
> 容器；refresh 把账本对齐现实）与 import 接管手工资源。零云、全免费。

## Background

Terraform 的经验（[`labs/03_tf_state`](../../labs/03_tf_state/)）已经演示过问题：
state 躺在本地文件里时一切正常；误删、换机或多人协作一来，账本与现实就对不上，
资源变成没人认领的"孤儿"。解法是远端 backend——state 存进 S3 兼容的对象存储。

Pulumi 沿用同一思路，但把"选后端"做成账户级开关：`pulumi login <url>` 或环境
变量 `PULUMI_BACKEND_URL` 指定账本放哪，一个后端下可以挂任意多个栈。本实验用
Docker 跑一个 MinIO 当私有 S3（与 labs/03 同款），演示账本搬家全程。

## What

**定义**：backend 是 state 的存放地。本地 file 后端把账本写成目录里的 JSON 文件；
S3 后端把同样的 JSON 存成桶里的对象——内容相同，只是"文件"变成了"对象 key"。

| 部件 | 角色 |
|:---|:---|
| `PULUMI_BACKEND_URL` | 选后端：`file://…` 或 `s3://桶?endpoint=…`（进程级，不碰全局登录） |
| `pulumi stack export / import` | 账本导出为 JSON 文件（序列化：把账本数据转成可保存、可传输的 JSON 文本）/ 从 JSON 文件灌回成账本——搬家的两只手 |
| `pulumi refresh` | 把账本对齐现实：现实少了对账本里的资源，就把它从账本划掉 |
| `pulumi import` | 把账本外的现实资源（手工创建的）收编进账本 |

可以把搬家想象成"店铺不挪窝、只换账本柜"：容器（店铺）照常营业，账本从
本地柜子誊抄进银行保险柜。但和真实誊抄不同的是——export/import 是字节级复制，
誊完 `up` 对账必须零差异；而且旧柜子里的账本还在，两本并存，以当前后端
URL 指向的那本为准。

![账本搬家与两次对账](images/state_backend.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/04_state_backend/images/state_backend.html)（或本地打开 [`images/state_backend.html`](images/state_backend.html)）。

看图方法：左边程序只管读配置；中上本地柜、中下 MinIO 桶是账本的两次安家
（虚线边 = 搬家与记账）；右侧"现实"区里，`pulumi04-web` 被账本托管，手工创建的
`pulumi04-stray` 靠 import 收编。

## When to Use

- 换机、重装、或把实验目录交给同事——账本要能跟着代码走；
- 多人共用一套环境：账本放远端，人人 `up` 前看到同一本账；
- 防误删：`.pulumi-state/` 在 `.gitignore` 里，删目录没人拦你，桶里另有一本。

何时不用：单人单机的玩具项目，file 后端零依赖、够用；远端后端的代价是要维护
MinIO/桶和访问凭据。

| 后端 | 差异 | 什么时候选 |
|:---|:---|:---|
| 本地 file | 账本是目录里的 JSON，随目录存亡 | 单人、单机、可随时重建的环境 |
| S3 兼容（MinIO 等） | 对象存储托管，零云、可自建 | 团队协作 / 本实验 / 生产上云前演练 |
| Pulumi Cloud（官方托管） | 附带并发锁与历史 UI，需注册 | 商业项目直接用，本系列不展开 |

## Quick Start

前置：Pulumi CLI、Node.js 22、Docker 运行中。建桶优先用 `minio/mc` 镜像
（自动拉取），宿主机有 `aws` CLI 时拉取失败会自动兜底。

```bash
cd pulumi/04_state_backend
./state_backend.sh          # 完整生命周期：apply → migrate → drift → adopt → clean
./state_backend.sh apply    # 本地 file 后端建栈 up，看账本目录结构
./state_backend.sh migrate  # 起 MinIO，账本 export→import 搬家，up 零 diff 对账
./state_backend.sh drift    # docker rm -f 制造漂移，refresh 检出 → up 自愈
./state_backend.sh adopt    # 手工容器被 import 接管，destroy 全清
./state_backend.sh clean    # 两后端销毁 + MinIO 下线，零残留
```

`migrate` 的真实输出（节选）：

```
        导出本地账本（stack export，账本可序列化）：
                13509 字节 → .logs/local-state.json
        切到 S3 后端，stack ls 应为空（新后端一本账都没有）：
        NAME  LAST UPDATE  RESOURCE COUNT
...
Resources:
    2 unchanged
```

搬家后 `up` 显示 `2 unchanged`：程序、容器、现实都没动，只有账本换了存放地。
随后的断言验证桶里确实多了一组对象（key 列表，6 条中的最后 2 条）：

```
        .pulumi/stacks/pulumi04-state-backend/dev.json
        .pulumi/stacks/pulumi04-state-backend/dev.json.bak
```

诚实预期：首次运行先 `npm install`；端口 28301/29000/29001 被占用会在断言处
报错。

对着 MinIO 操作时 AWS SDK 可能打 `Response has no supported checksum` 警告，
脚本已设 `AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED` 消音。

（首次 `migrate` 还会拉 `minio/mc` 镜像，拉取失败自动改用宿主 `aws` CLI 建桶。）

## How It Works

### 后端选择：进程级环境变量，不碰全局

`pulumi login <url>` 把后端写进 `~/.pulumi`，影响这台机器的所有项目；本实验改用
`PULUMI_BACKEND_URL`——只影响当前进程，clean 后零痕迹。S3 后端的端点与
path-style（桶名进路径的寻址方式）写进 URL 查询参数：

```bash
PULUMI_BACKEND_URL="s3://pulumi04-state?endpoint=http://localhost:29000&s3ForcePathStyle=true"
```

注意 `&` 要引号包住整个 URL，否则 shell 会把命令切成两截。

### 搬家三步：export → init → import

```bash
pulumi stack export --stack dev > local-state.json     # 账本 → JSON（13.5 KB）
pulumi stack init dev                                  # 新后端建空栈
pulumi stack import --file local-state.json            # JSON 回灌新栈
```

回灌后立刻 `up` 对账：零 diff 才算搬成功。迁移是复制不是移动——本地
`.pulumi-state/` 里的旧账原封不动，只是不再被读取；`stack select` 前先看当前
`PULUMI_BACKEND_URL` 指向哪本。

### 本地路径 = 桶内 key：一本账的两种存法

`apply` 段打印的目录树（节选，每个文件另有同名 `.attrs` 伴随文件）：

```
        ./.pulumi/backups/pulumi04-state-backend/dev/dev.1792073983119277000.json
        ...
        ./.pulumi/stacks/pulumi04-state-backend/dev.json
```

backups 下每次写账留底一次（`dev.<时间戳>.json`），history 存每次操作的执行
历史，`stacks/…/dev.json` 是账本本体。

迁到 MinIO 后，`s3api list-objects` 看到的 key 与这些路径完全同构——backend
只换"文件放哪"，不换"文件长什么样"。

### 两次对账：refresh 对齐现实，import 收编现实

`drift` 段手工 `docker rm -f` 掉容器后，`refresh` 输出
`- 1 deleted`（账本划掉它），随后 `up` 重建 `+ 1 created`——远端账本一样能自愈。

`adopt` 段反方向：手工 `docker run` 的容器账本里没有，`import` 按容器 ID
（64 位长 ID，`docker inspect` 取）收编进账本。

但期望态由程序定义：`preview` 直言下场——`- 1 to delete`，账本里有、程序里
没有的资源会在下一次 `up` 被删除。最终 `destroy` 把托管与收编的一起清空
（`- 3 deleted`）。

## Pitfalls & Q&A

- **① import 报 `resource does not exist`**：p-docker（即 Pulumi 的 Docker
  提供包 `@pulumi/docker`，5.2.0 是本实验 `package.json` 固定的版本）的 import
  只认容器 64 位长 ID，给名字不行。`docker inspect --format '{{.Id}}' <名字>`
  先取 ID。
- **② S3 环境变量不认**：`AWS_ENDPOINT_URL`、`AWS_S3_FORCE_PATH_STYLE` 对
  Pulumi 的 s3 backend 无效（实测报 `InvalidBucketName`）；端点与 path-style
  只能写进 `s3://` URL 的查询参数。
- **③ `--file` 相对路径解析在 `-C` 目录**：`pulumi -C program stack import
  --file .logs/…` 找不到文件——相对路径相对 `program/` 解析，脚本里用绝对路径。

Q&A：

- **搬家会动容器吗？** 不会：export/import 只碰 JSON，`up` 对账显示
  `2 unchanged`，容器全程在线。
- **两本账并存，以谁为准？** 以当前 `PULUMI_BACKEND_URL` 指向的那本为准；
  同名栈在不同后端是两个独立的栈。
- **自管后端有并发锁吗？** 没有：file / S3 后端不锁，两人同时 `up` 会互相
  踩账本；团队协作要么约定轮流，要么上 Pulumi Cloud（带锁）。Terraform 的
  S3 backend + DynamoDB 锁方案对照见 [`labs/03_tf_state`](../../labs/03_tf_state/)。
- **桶被误删了怎么办？** 账本没了 Pulumi 就"失忆"，真实资源变孤儿；`refresh`
  救不回来（它只会向现实对齐）。远端后端的价值正在于此：桶配好版本化或备份，
  账本才真正可靠。
