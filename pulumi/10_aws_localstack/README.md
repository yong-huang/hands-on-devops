# 10 · AWS Provider：endpoint 决定环境

> S3（AWS 的对象存储：数据装在名为「桶」的容器里，每个文件是一个「对象」）
> 的桶与对象，在 Pulumi（用通用编程语言声明云资源的基础设施即代码工具）里的
> 声明方式与真 AWS 完全一致——唯一的环境差异是 provider 指向哪。
>
> 把 endpoints 指向本机 LocalStack（AWS API 模拟器），云资源开发就离线化：
> `aws` CLI 对同一个桶读写自如，改一行配置 `up`（Pulumi 创建/更新资源的命令）
> 即原地更新，destroy（Pulumi 删除资源的命令）后零残留。零云、零成本。

## Background

01-09 号实验换过三种 provider（Pulumi 中把资源声明翻译成目标平台 API 的插件：
Docker / Kubernetes / 又回到 Docker），规律已经明显：期望态（声明的资源最终
应该长成什么样）模型不变，变的只是翻译目标。

AWS 是云资源的最大方言区，直接对着真 AWS 学有三个障碍：要注册、要花钱、要
网络。LocalStack（本机 AWS API 模拟器，单容器）把这三个障碍一起搬走——endpoint
指向 localhost:4566，从此"云资源"在本地跑。

LocalStack 免费版需注册 token（访问凭证字符串；本机已在 hands-on-aws 系列
配好——`auth.json` 即 LocalStack 存放凭证的配置文件，生效后自动激活
freemium 授权，即基础功能免费的模式）。

## What

**定义**：`aws.Provider` 的职责是回答四个问题——连到哪（endpoints）、自称是谁
（accessKey/secretKey）、要不要验证身份（skip 两个开关）、桶名怎么寻址
（s3UsePathStyle）。

四问答完，后面的 S3 资源声明与真 AWS 没有任何区别。

| 部件 | 取值 | 为什么 |
|:---|:---|:---|
| `endpoints` | `{ s3/sts/iam: http://localhost:4566 }` | 7.x 按服务覆写；少覆写一个就打到真 AWS（见 Pitfalls ②） |
| `accessKey/secretKey` | `test` / `test` | LocalStack 不校验内容，但字段必须给 |
| `skipCredentialsValidation` | `true` | 跳过对真 AWS 的凭证验证 |
| `skipRequestingAccountId` | `true` | 跳过启动时的账号 ID 查询 |
| `s3UsePathStyle` | `true` | LocalStack 只认 path-style（桶名进路径） |

sts（Security Token Service，查账号身份的 AWS 服务）与 iam（Identity and
Access Management，管用户与权限的 AWS 服务）也是 AWS API，provider 启动时会
用到；"7.x" 指 aws 插件的大版本。

可以把 provider 想象成快递面单：货（资源声明）一模一样，面单上的地址决定它
发往真 AWS 还是本机模拟器。失效边界：模拟器不是完美复刻——真 AWS 的区域、
配额、部分服务行为有差异，LocalStack 验证过的是"声明写法"与"主流程"，上生产
仍要真环境小规模试跑。

![endpoint 决定环境](images/aws_local.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/10_aws_localstack/images/aws_local.html)（或本地打开 [`images/aws_local.html`](images/aws_local.html)）。

看图方法：程序声明期望态，provider 把 S3/sts/iam 三个 API 指向 localhost:4566，
右侧 LocalStack 区域里桶与对象就是"云资源"——`aws` CLI 交叉验证的是同一个桶。

## When to Use

- 云资源声明还没上生产前：本地迭代 S3/IAM/队列等声明，零成本试错；
- CI（持续集成：合并前自动跑检查的流水线）里验证 IaC（Infrastructure as
  Code，基础设施即代码）声明：LocalStack 起容器即用，跑完即弃（项目 12 将以
  它做合并前的自动检查底座）；
- 团队规范沉淀：策略包、组件库对着模拟器先跑通再上真云。
- 反例：模拟器能力有边界（个别服务缺功能、行为差异），最终验收必须回真 AWS
  小规模试跑——LocalStack 是开发与 CI 环节，不是替代验收。
- 和同类方案怎么选：真 AWS 免费层要注册且有计费风险，只适合最终验收；MinIO、
  Moto 只覆盖单服务或代码级 mock——要多服务 API 且与真 AWS 行为一致的本地
  开发环境，选 LocalStack。

## Quick Start

前置：Pulumi CLI、Node.js 22、Docker、LocalStack CLI。aws 插件数百 MB，脚本
只预装一次；LocalStack 未运行时自动拉起（约 30 秒）。

LocalStack 2026-03 起需免费 token：没配过的机器先到 localstack.cloud 注册
账号获取 token，按官方文档写入本地 `auth.json` 再跑；未配置时脚本会在
「拉起 LocalStack」一步失败。

```bash
cd pulumi/10_aws_localstack
./aws_local.sh          # 完整生命周期：apply → update → clean
./aws_local.sh apply    # up 建 bucket+对象 → aws cli 交叉验证
./aws_local.sh update   # 改对象内容再 up：原地更新（bucket 不动）
./aws_local.sh clean    # destroy 后断言桶消失（LocalStack 保留运行）
```

`apply` 段的交叉验证（真实输出）：

```
        aws s3 ls（经 LocalStack）：
        2026-10-16 10:57:29 pulumi10-demo
        ……（交叉验证：本地写文件 → cp 进桶 → 拉回比对 → 删除桶内副本）
        [ok] aws cli 对同一个桶读写自如——Pulumi 声明的就是真实 S3
```

本地写文件 → `aws s3 cp` 进桶 → 拉回 diff 比对逐字节一致；`update` 段把对象
内容配置改为 v2 再 `up`，diff 只有对象原地更新，桶内 `hello.txt` 立即是 v2。

`clean` 段 destroy 后 `aws s3 ls` 查无此桶。

诚实预期：LocalStack 容器残留 stopped 状态时 `start -d` 会报 already exists，
脚本自动先 `docker rm -f` 再启动；停止模拟器用 `localstack stop`（本实验不代劳）。

## How It Works

### provider 四问的落地

```ts
const provider = new aws.Provider("localstack", {
    region: "us-east-1",
    accessKey: "test",                    // LocalStack 不校验凭证，但要给
    secretKey: "test",
    skipCredentialsValidation: true,      // 跳过对真 AWS 的凭证验证（否则启动就报错）
    skipMetadataApiCheck: true,           // 跳过 EC2 metadata 探测（本机没有）
    s3UsePathStyle: true,                 // LocalStack 只认 path-style（桶名进路径）
    skipRequestingAccountId: true,        // 不向 STS 查账号 ID（LocalStack 无意义）
    // endpoint 按服务覆写（7.x 的形态）：只覆写 S3 不够——provider 启动还会调
    // STS/IAM，不覆写就打到真 AWS 上报 InvalidClientTokenId
    endpoints: [{
        s3: "http://localhost:4566",
        sts: "http://localhost:4566",
        iam: "http://localhost:4566",
    }],
});
```

`endpoints` 是 7.x 的形态：一个数组、每个元素按服务名覆写。

**只覆写 s3 不够**——provider 初始化时会调 STS（查账号身份）与 IAM（列角色），
这两个调用不打向 LocalStack 就落到真 AWS，用假凭证换来一屏
`InvalidClientTokenId` 403。

### 交叉验证：两条通道，一个世界

Pulumi 经 provider 写桶，`aws --endpoint-url http://localhost:4566 s3 ls`
经同一 API 读桶——两条通道对着同一个模拟器。`cp` 上传、下载、diff 三步证明
声明的桶不是 Pulumi 的私有账本，是真实的 S3 API 对象存储。

### update：配置驱动的内容更新

对象 `content` 走配置，`update` 段只改配置再 `up`：引擎（Pulumi 中对比期望态与现实、决定执行哪些
改动的核心）diff 出"对象内容变了"，
向 LocalStack 发 PutObject——bucket 原地不动。与实验 03 的密钥轮换同一模式：
参数进配置，环境差异不进程序。

## Pitfalls & Q&A

- **① `endpoint` 属性不存在**：aws 7.x 改为 `endpoints`（数组、按服务覆写），
  老教程的单数 `endpoint` 会直接报 TS2561（TypeScript 编译错误：对象字面量
  只能写类型已知的属性名）。
- **② 403 InvalidClientTokenId**：只覆写 s3 时，provider 启动期的 STS/IAM
  调用打到真 AWS。sts、iam 也要进 `endpoints`，再加
  `skipRequestingAccountId: true`。
- **③ LocalStack 残容器**：上次异常退出留下 stopped 的 `localstack-main`，
  再 `start -d` 报 already exists——先 `docker rm -f localstack-main`。
- **④ 健康检查的状态词变了**：`/_localstack/health` 的 s3 状态新版是
  `running`（老版 `available`），脚本断言两者都放行。

Q&A：

- **假凭证 `test/test` 安全吗？** 它只发给 LocalStack（endpoint 钉死
  localhost），且 provider 已 `skipCredentialsValidation`；真 AWS 凭证永远
  不进这个实验。
- **这套声明能直接上真 AWS 吗？** 能：删掉 `endpoints` 与两个 skip、换成真
  凭证与 region，资源声明一字不改——这正是"endpoint 决定环境"的收益。
- **destroy 会误删真云资源吗？** 不会：栈（stack，Pulumi 的部署单元）的账本
  （state，记录每个资源由哪次部署创建）记的是 endpoint 指向的那个世界建的
  资源；只要 provider 的 endpoints 还指着 LocalStack，destroy 的
  边界就在模拟器内。
