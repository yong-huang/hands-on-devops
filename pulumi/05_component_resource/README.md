# 05 · ComponentResource：一份组件，两套实例

> 站点服务写第二遍时，复制粘贴就开始生根：同样的网络 + 容器 + 端口连线，改个名
> 再来一份。Pulumi 的组件（ComponentResource）把"一组资源及其连线"封装成一个
> 类——入参是 args、返回值是 outputs、内部资源对外不可见，对标 Terraform 的
> module（[`labs/02_tf_modules`](../../labs/02_tf_modules/)）。本实验实例化两套
> 服务，并验证"改组件一行，两实例同步更新"。

## Background

[`labs/02_tf_modules`](../../labs/02_tf_modules/) 用 Terraform module 解决过同一个
问题：web 服务 = 网络 + 容器，这份"做法"写一次、实例化 N 次。没有封装时，第二
套环境就是第一套的复印件——改端口映射规则要记得改两处，漏一处就是一次漂移。

Terraform 的答案是 module：一份 `.tf` 文件 + variables（入参）+ outputs（出参），
用 `source` 引用。Pulumi 不需要发明新机制——封装就是编程语言原生的类。组件
继承 `pulumi.ComponentResource`，构造函数里创建子资源，仅此而已。

## What

**定义**：ComponentResource 是账本（即 Pulumi 的 state——记录"这次部署管了哪些
资源、各自什么属性"的清单文件，下文 state 同指它）里的一种"组合资源"——它自身
不对应真实设施，只是把一组子资源挂在自己名下（parent），形成可复用、可命名的
封装单元。

| 部件 | 角色 | TF module 对照 |
|:---|:---|:---|
| `class WebService` | 组件类：一段"做法"写一次 | 一个 module 目录/块 |
| `WebServiceArgs` 接口 | 入参，类型检查在编译期 | `variables` 块 |
| `registerOutputs` | 出参，注册进账本供引用 | `outputs` 块 |
| `{ parent: this }` | 子资源挂到组件名下，形成 URN（Pulumi 给每个资源的全局唯一全名，形如 `urn:pulumi:栈::项目::类型::逻辑名`）父子树 | module 内资源的嵌套地址 |
| `new WebService("alpha", …)` | 实例化一次 | 一处 `module "alpha"` 引用 |

可以把组件类想象成"图纸"，实例是"按图施工的楼盘"：两栋楼盘结构相同、门牌
不同（端口/镜像来自 args）；改图纸一根梁，两栋一起返工——但图纸本身不是楼，
账本里它只是一条目录性质的记录。失效边界：与图纸不同的是，组件实例化发生在
每次 `up` 执行程序时，图纸改了但没 `up`，楼盘不动。

![一份组件，两套实例](images/component_resource.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/05_component_resource/images/component_resource.html)（或本地打开 [`images/component_resource.html`](images/component_resource.html)）。

看图方法：左边组件类是唯一入口；右上/右下两个实例区各藏一套"网络 + 容器"，
内部连线（挂网）对调用方不可见；两条"实例化 · parent"边就是 URN 里 `$` 的来源。

## When to Use

- 同一组资源的组合第二次出现——组件化的收益从这一刻开始；
- 想给调用方一个窄接口：暴露 url，藏住网络拓扑与命名规则；
- 团队要"内部平台"：把公司规范（标签、命名、镜像来源）焊死在组件里。
- 反例：只出现一次的资源组合，直接写资源更直白，多一层组件是纯包装。

## Quick Start

前置：Pulumi CLI（`brew install pulumi`）、Node.js 22、Docker 运行中。

```bash
cd pulumi/05_component_resource
./component_resource.sh          # 完整生命周期：apply → urns → evolve → clean
./component_resource.sh apply    # 组件实例化两套服务
./component_resource.sh urns     # 看 URN 父子树（账本/state 里每个资源带 parent 字段）
./component_resource.sh evolve   # 改组件一行 → 两实例同步更新
./component_resource.sh clean    # 销毁全清
```

`apply` 的真实输出（节选）：

```
 +  hands-on:service:WebService alpha create 
 +  hands-on:service:WebService beta create 
 +  docker:index:Container alpha-web create 
...
Resources:
    + 7 created
```

组件本身也是账本里的一条资源（`hands-on:service:WebService alpha`），连同两个
网络、两个容器与栈（stack，一次部署的一个独立账本实例，本实验栈名为 dev），
正好 7 条。

端口与镜像全部来自 args：`pulumi05-alpha-web` 跑 `nginx:1.27-alpine` 于 :28401，
`pulumi05-beta-web` 跑 `nginx:1.25-alpine` 于 :28402，两个端口 curl 均命中 nginx
欢迎页。

诚实预期：首次运行先 `npm install`；端口 28401/28402 被占用会在断言处报错；
`evolve` 段会临时改写 `program/component.ts`，脚本装有退出守护（trap），中断也
会还原源文件。

## How It Works

### 组件三件套：类、args、outputs

```ts
export class WebService extends pulumi.ComponentResource {
    public readonly url: pulumi.Output<string>;
    constructor(name: string, args: WebServiceArgs, opts?: pulumi.ComponentResourceOptions) {
        super("hands-on:service:WebService", name, {}, opts);   // 类型标签进 URN
        const net = new docker.Network(`${name}-net`, { … }, { parent: this });
        const web = new docker.Container(`${name}-web`, { … }, { parent: this });
        this.url = pulumi.interpolate`http://localhost:${args.port}/ (${web.name})`;
        this.registerOutputs({ url: this.url });
    }
}
```

三个关键点：`super` 的第一个参数是组件类型标签（进 URN，习惯写成
`包:模块:类型`）；每个子资源都带 `{ parent: this }`，这是父子树的来源；
`registerOutputs` 把 url 登记进账本，下游才能引用。

调用方 `index.ts` 只有两行 `new WebService(…)`——与 labs/02 里两段 `module`
块逐行对应。

### URN 父子树：`$` 就是 parent 边

`urns` 段的实测输出（`pulumi stack --show-urns`，节选）：

```
            ├─ hands-on:service:WebService          alpha
            │  │  URN: urn:pulumi:dev::pulumi05-component-resource::hands-on:service:WebService::alpha
            ...
            │  └─ docker:index/container:Container  alpha-web
            │        URN: urn:pulumi:dev::pulumi05-component-resource::hands-on:service:WebService$docker:index/container:Container::alpha-web
```

子资源的 URN 里出现 `$`：`$` 前面就是 parent。对照实验 03——那里资源直接挂在
栈下，URN 没有 `$`。

父子关系不靠命名约定：账本里每个资源都有 `parent` 字段，脚本据此断言"全部
容器的 parent 都指向 WebService 组件"。

### 演化：改组件一行，两实例同步 replace

`evolve` 段在组件内部的容器声明里插入一行 `envs: ["COMPONENT_VERSION=v2"]`
（`index.ts` 一字未动，源文件由 trap 守护自动还原），`up` 的真实输出（节选）：

```
 -- docker:index:Container beta-web delete original 
 +- docker:index:Container beta-web replace [diff: +envs]
 ++ docker:index:Container beta-web create replacement [diff: +envs]
 -- docker:index:Container alpha-web delete original 
 +- docker:index:Container alpha-web replace [diff: +envs]
 ++ docker:index:Container alpha-web create replacement [diff: +envs]
...
Resources:
    +-2 to replace
    5 unchanged
```

两个容器一起走 replace（环境变量变更不能原地去改，与实验 03 的密钥轮换同一
形态），网络与栈纹丝不动。替换后 `docker inspect` 验证两实例都拿到
`COMPONENT_VERSION=v2`——组件是复用单位，改的是"做法"，所有"成品"跟着更新。

## Pitfalls & Q&A

- **① diff 标记看清楚 `+envs` 还是 `~envs`**：新增一个环境变量是 `+envs`，
  修改已有变量的值才是 `~envs`（实验 03 的轮换）；都走 replace，但读 diff 时
  别被符号差异迷惑。
- **② 实例名是逻辑名空间**：子资源逻辑名是 `${name}-web`——把实例从 `alpha`
  改名为 `gamma` 等于全部删旧建新（逻辑名即身份，实验 02 的教训在组件里同样
  成立）。
- **③ 组件会被 destroy**：`clean` 段输出 `- 7 deleted` 里含两条 WebService——
  组件是账本里的真实条目，销毁时与子资源一起从账本消失。

Q&A：

- **组件和 TF module 的本质差别？** module 是 DSL（领域专用语言，这里指
  Terraform 自带的 HCL 配置语法）层的引用机制；组件是语言原生的类——构造函数里
  可以写任意逻辑（条件、循环、调用库），类型检查与单元测试直接复用 TS 生态。
- **两套实例会互相影响吗？** 不会：`alpha` 与 `beta` 在账本里是两棵独立的
  子树，唯一共享的是组件代码——这正是演化实验的前提（改代码才波及两者，
  改一个实例的参数不影响另一个）。
- **什么时候该抽组件？** 同一组合出现第二次时。只出现一次就抽，等于为唯一的
  楼盘先画通用图纸——灵活性换来的复杂度没有回报。
