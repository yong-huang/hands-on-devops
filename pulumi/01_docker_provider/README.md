# 01 · Pulumi Docker Provider：第一个程序与 CLI 回路

> `docker run` 拉起的容器，参数只活在 shell 历史里；`docker ps` 看得见现状，说不清
> "它应该是什么样"。Pulumi 把期望态写成 TypeScript 程序交给引擎执行——本实验跑通
> preview → up → destroy 回路，并制造一次漂移验证自愈；零云、全免费。

## Background

命令式地 `docker run`、`docker network create`，每一步都靠人记住。问题出在"第二天"：
容器挂了要重建，参数只能翻 shell 历史；换机器或同事接手，没有可对照的"标准答案"。

Terraform 给出一半答案：用 HCL（HashiCorp 为基础设施设计的配置语言）声明期望态，
引擎算 diff 再执行；代价是多学一门语言，已有的 TypeScript / Python 技能与测试
框架用不上。

Pulumi（2018 年开源）去掉这层负担：直接用通用编程语言写资源声明，引擎执行程序
得到期望态——类型检查、函数复用、IDE 补全原生可用。同题 Terraform 版本见：

[`labs/01_tf_docker_provider`](../../labs/01_tf_docker_provider/)

## What

**定义**：Pulumi 是 IaC（Infrastructure as Code，把基础设施当代码声明、评审、
执行）引擎：执行你用通用编程语言写的程序得到期望态，与 state 记账本对账，
经 provider 调用真实 API 收敛实际状态。

| 部件 | 角色 |
|:---|:---|
| `pulumi` CLI | 执行程序、算 diff、跑更新（本实验唯一要安装的东西） |
| 程序（本实验为 TypeScript） | 期望态声明：资源、参数、依赖关系 |
| provider 插件 | 把引擎指令翻译成平台 API 调用（docker / kubernetes / aws …） |
| state 后端 | 记账本；本实验用本地文件，对象存储等后端实验 4 展开 |

可以把 Pulumi 程序想象成一份会"自动对账"的装修清单：施工队拿着它对照现场，缺的
补、多的拆；但它是能循环、能分支、能 import 的活程序。

![Pulumi Docker Provider 收敛回路](images/pulumi_docker_provider.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/01_docker_provider/images/pulumi_docker_provider.html)（或本地打开 [`images/pulumi_docker_provider.html`](images/pulumi_docker_provider.html)）。

看图方法：左边程序（期望态）→ 中间引擎与 state 对账 → 右边 docker provider 驱动 daemon 收敛；下方 refresh 回路是漂移检测入口。

## When to Use

- 团队技术栈是 TypeScript / Python，希望复用类型系统与测试框架写基础设施；
- 基础设施里动态逻辑多——按数组循环创建、按条件开关资源（实验 2 专门演练）；
- 一个程序要混合编排多个平台（Docker + Kubernetes + AWS，实验 9-11 演练）。
- 反之（静态小规模环境）HCL 更直白；团队完全不写应用代码时，多引入一个语言
  运行时也是负担。

| 方案 | 核心差异 | 什么时候选 |
|:---|:---|:---|
| Pulumi | 通用语言 + 引擎 | 已有编程栈、要复用测试与类型、多平台混合编排 |
| Terraform | HCL 专用语言 + 引擎 | 不引入语言运行时，HCL 生态与模块最成熟 |
| AWS CDK（AWS 官方工具包，用编程语言声明云资源） | 通用语言，编译成 CloudFormation 模板（AWS 原生的资源声明格式） | 只用 AWS，且已在用 CloudFormation |

## Quick Start

前置：Pulumi CLI（`brew install pulumi`）、Node.js 22、Docker 运行中。

```bash
cd pulumi/01_docker_provider
./docker_provider.sh          # 完整生命周期：apply → observe → drift → clean
./docker_provider.sh apply    # 只创建
./docker_provider.sh observe  # 只观察（三方对照 + 幂等断言）
./docker_provider.sh drift    # 只演示"删容器 → 检出 → 自愈"
./docker_provider.sh clean    # 只销毁
```

`apply` 的真实输出（节选，进度行与 Outputs 段省略）：

```
Updating (dev):

 +  docker:index:Network net created (2s) 
 +  docker:index:Container app created (0.97s) 

Resources:
    + 3 created
```

随后脚本用 docker 视角验证容器、网络与 curl，任一不符即报错退出。

诚实预期：首次运行先 `npm install` 再下载 docker provider 插件（约 1-2 分钟，
之后走缓存）；若 28081 被占用，"curl 命中 nginx"会报错——停掉占用者；换端口需
同步改 `program/index.ts` 的 external 与导出 url、脚本三处 28081。

## How It Works

### 程序：两个资源与一条依赖边

```ts
const net = new docker.Network("net", { name: `${appName}-net` });
const app = new docker.Container("app", {
    name: `${appName}-nginx`,
    image: "nginx:1.27-alpine",
    ports: [{ internal: 80, external: 28081 }],
    networksAdvanced: [{ name: net.name }],   // 引用 net.name = 一条依赖边
});
```

`"net"` / `"app"` 是 state 里的逻辑名（进 URN，全栈唯一标识符），`name` 才是
Docker 真名。`net.name` 是 `Output<string>`——创建后才有值的"未来值"，谁引用
它谁就建立依赖边，引擎据此自动排序（先网络、后容器），无需手写。

### 回路：preview / up / destroy 各自对 state 做什么

- `preview`：执行程序得到期望态，与 state 对账只打印计划，不碰真实资源；
- `up`：执行计划调 API 收敛，把结果写回 state（这一步叫记账）；
- `destroy`：按 state 逆序删除资源，state 归零但栈保留，可反复 apply。

`pulumi stack` 可查看 state 资源树：栈（一组 state 的命名空间）→ Network →
Container → provider 插件记录；同一程序可初始化多个栈跑不同参数（dev / prod），
实验 3 展开。

state 实体是 JSON，存在实验目录 `.pulumi-state/.pulumi/stacks/…/dev.json`；栈初始化要求口令
`PULUMI_CONFIG_PASSPHRASE` 加密敏感值——实验用固定口令，真实项目密钥治理见实验 3 / 24。

### 漂移：裸 preview 看不见，refresh 才检出

`drift` 段先 `docker rm -f pulumi01-nginx`；裸 preview 的 `Resources` 段仍是
`3 unchanged`——账本没坏，它按上次的账本回答，默认不刷新实际状态。显式对账
`pulumi refresh` 才检出（节选，进度行与 Outputs 段省略）：

```
 ~  docker:index:Container app refreshing (0s) 
 -  docker:index:Container app deleted (0.10s) 
Resources:
    - 1 deleted
    2 unchanged
```

再 `up` 即按期望态重建、服务恢复；`pulumi up --refresh` 可把两步合成一步。

## Pitfalls & Q&A

- **① 后端准备两件事**：目录必须先存在（否则 `unable to open state directory`）、
  口令必须设置（否则 `passphrase must be set`）；脚本已内置。
- **② 裸 preview 说 3 unchanged**：不是失灵；与 `terraform plan` 默认 refresh
  不同，需 `refresh` / `--refresh` 才对账实际状态。

Q&A：

- **stop 容器和 rm 容器处理方式一样吗？** 不一样：stop 后 refresh 报
  `[diff: -ports~mustRun]`、up 走 replace；rm 后 refresh 报
  `- delete`、up 直接 create。都自愈，但计划形态不同。
- **state 里有什么，能删吗？** 资源 URN、身份 ID、属性快照与依赖。删了 Pulumi
  就"失忆"，真实资源变孤儿（实验 4 有接管与恢复演练）。
- **docker provider 能管生产吗？** 适合本地靶场；生产换 kubernetes / 云
  provider——期望态模型一致，这正是拿 Docker 练手的价值。
