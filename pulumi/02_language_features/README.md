# 02 · 编程语言的力量：循环 / 条件 / 函数写基础设施

> 站点从 2 个涨到 3 个，手写复制粘贴还能忍；涨到 20 个呢？本实验把期望态（你希望
> 基础设施最终呈现的样子）交给语言本身：数组驱动循环、条件分流、函数封装模式——
> 扩容只对差集动手。2→3→2 的增量收敛与编译期类型拦截，全程本机真机验证。

## Background

项目 1 的两个资源是手写的。现实里站点清单会长：复制粘贴一段容器声明、改名字
改端口，漏一个就少一个站点，改错一行就是一处漂移（声明的与实际跑的就此对不上）。

HCL（Terraform 的配置语言）给了两种批量声明：`count`（按个数复制）与 `for_each`
（按集合逐项展开）。够用，但逻辑一复杂就要和 DSL 较劲：拼字符串、算条件、嵌套
`for` 表达式塞进 `locals`，很快触到表达能力的天花板——HCL 里没有普通函数。

Pulumi（用通用编程语言写基础设施的工具）不做"有限循环"：循环、条件、函数就是
你写应用代码用的那些。同题的 Terraform 版本（for_each 双实例 + module 封装）见
[`labs/02_tf_modules`](../../labs/02_tf_modules/)。

## What

**定义**：程序化基础设施是把"建什么"和"怎么算出来"分开——数据（站点清单）住进
数据文件、加工逻辑（循环 / 条件 / 函数）住进程序，引擎把执行结果变成资源动作。

可以把 `sites.ts` 想象成一张菜单、`makeSite()` 想象成后厨：加一道菜只改菜单，
做法不用动——但菜品（资源）由引擎对比新旧差异后精确上撤，没点的菜不会重做。

![站点清单驱动的 N 资源收敛](images/sites_loop.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/02_language_features/images/sites_loop.html)（或本地打开 [`images/sites_loop.html`](images/sites_loop.html)）。

看图方法：左边数据（sites.ts）→ 程序（循环 / 条件 / 函数）把数组逐项加工成资源声明，
引擎与 state（记录已管资源的台账）对账后，由 docker provider（把引擎指令翻译成
Docker 调用的插件）扇出到下方：共享网络 + N 个容器。

## When to Use

- 实例数量不定、且来自数据（数组、配置文件、外部接口的查询结果）；
- 同一套资源模式要按参数分流（环境、渠道、版本——本项目里是 stable / preview）；
- 配置逻辑有分支和计算（拼名字、算端口、条件选镜像 tag）。

反例：三五个静态资源，HCL 直接声明更一目了然；程序的自由度用不上时就是纯负担。

## Quick Start

前置：Pulumi CLI（`brew install pulumi`）、Node.js 22、Docker 运行中。

```bash
cd pulumi/02_language_features
./language_features.sh          # 完整生命周期：apply → observe → scale → fail → clean
./language_features.sh apply    # 从数组创建 2 个站点
./language_features.sh scale    # 数组 2→3→2，观察增量收敛
./language_features.sh fail     # 故意写错类型，看 tsc 在部署前拦住
./language_features.sh clean    # 只销毁
```

`apply` 的真实输出（节选）：

```
 +  docker:index:Container site-beta created (2s) 
...
Resources:
    + 4 created
```

随后脚本断言：2 个容器在跑、两个端口 curl 命中 nginx 欢迎页，且条件表达式确实
分流了镜像——`alpha -> nginx:1.27-alpine`、`beta -> nginx:1.25-alpine`。

诚实预期：首次运行先 `npm install` 与 provider 插件下载（约 1-2 分钟）；端口
28091-28093 被占用会在 curl 断言处报错；`scale` / `fail` 段会临时改写
`program/` 里的源文件，跑完自动还原（脚本装了退出守护，中断也安全）。

## How It Works

### 数据与程序分离：加一行 = 多一个站点

`program/sites.ts` 是唯一数据源；`channel` 只能是 `"stable" | "preview"` 两个字面量，拼错编译器直接拦：

```ts
export const WEB_SITES: Site[] = [
    { name: "alpha", port: 28091, channel: "stable" },
    { name: "beta", port: 28092, channel: "preview" },
];
```

### 循环、条件、函数：三件事各归各位

```ts
const image = site.channel === "preview" ? "nginx:1.25-alpine" : "nginx:1.27-alpine";
return new docker.Container(`site-${site.name}`, { name, image, ports, networksAdvanced });
for (const site of WEB_SITES) containers.push(makeSite(site));
```

（节选示意；完整版见 `program/index.ts`。）条件表达式是普通的三元；函数 `makeSite()`
把"做法"（镜像策略、命名、端口、挂网）写一次；循环遍历数据数组。资源逻辑名
`site-alpha` / `site-beta` 出现在 `pulumi stack` 资源树里——循环逐项展开的痕迹。

### 对照表：同一诉求，两种表达

| 想要的效果 | HCL（Terraform） | TypeScript（Pulumi） |
|:---|:---|:---|
| 按集合批量建资源 | `for_each = var.sites` / `count = 2` | `for...of` 循环 / `.map()` |
| 条件选值 | 三元表达式（能力有限） | 同样的 `? :`，两个分支都有类型检查 |
| 封装一组配置 | `module` + 变量 / 输出 | 普通函数（可返回任意数据结构） |
| 数据加工 | `locals` + 嵌套 `for` 表达式 | 语言原生：filter / sort / 读文件 |
| 错误拦截时机 | `terraform validate`（检查范围有限） | `tsc` 全类型系统，IDE 实时提示 |
| 逻辑天花板 | DSL 表达能力为界 | 语言表达能力为界 |

### 增量收敛：只对差集动手

`scale` 段把数组换成 3 站点版本再 up，真实输出（节选）：

```
 +  docker:index:Container site-gamma create 
...
Resources:
    + 1 to create
    4 unchanged
```

`+ 1 to create` / `4 unchanged`：alpha、beta 一行未动，只有 gamma 被创建，连输出
`urls` 数组都自动多了一项；反方向（还原 2 站点）同理，只删 gamma。

### 部署前的类型拦截

`fail` 段把端口写成字符串（`external: site.name`）再跑 `tsc`，真实输出：

```
index.ts(16,33): error TS2322: Type 'string' is not assignable to type 'Input<number | undefined>'.
```

编译期拒绝：部署根本没机会发生（`terraform validate` 的检查粒度做不到这一点，
对照见上表）。

## Pitfalls & Q&A

- **① 报错里的 `Input<number | undefined>` 是什么**：Pulumi 把每个属性包成
  `Input<T>`（普通值或 `Output<T>` 都能塞）；错的是给进去的 string。
- **② 逻辑名就是资源身份**：`site-${site.name}` 改名 = 删旧建新。别用数组
  下标拼逻辑名——中间删一项，后面全部位移、全部重建（实验 4 讲 state 手术）。
- **③ 无依赖的资源会并行创建**：日志里 alpha / beta 同时 creating——期望态是
  一张依赖图，不是顺序脚本。

Q&A：

- **这和 HCL 的 for_each 本质区别是什么？** for_each 是引擎开放的"有限批量
  声明"；这里是语言本身的循环——数据可从任意来源算出，逻辑可嵌套、可提前
  return、可调库。上限完全不同。
- **数组能从外部来吗（文件 / 接口）？** 能：Pulumi 先执行你的预处理代码再建
  资源。代价是对可重复性要求更高——同输入同结果，否则每次 up 都是新期望态。
