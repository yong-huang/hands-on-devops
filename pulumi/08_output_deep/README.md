# 08 · Output 深水区：取值边界与依赖图

> Output 是本系列 TS 主线最大的坑区：把它当普通值用，编译器不报错、运行时才炸。
>
> 本实验把每个陷阱做成最小可复现例子——顶层取值被引擎（执行程序、创建资源并
> 写账本的组件）当场拒绝并给出修法，apply 回调里才是普通值；隐式属性依赖与
> 显式 dependsOn 都写进账本（state：引擎维护的部署档案），两种并行度结果一致。

## Background

`net.name` 这类值是"创建后才知道的未来值"——实验 01
（[`../01_docker_provider`](../01_docker_provider/)）只用过它"引用即排序"这一层。

真写起来，第一反应永远是把它当字符串用：拼进 `console.log`、存进变量、放进
条件判断——TS 编译器全放行，直到 `up`（Pulumi 的部署命令）时引擎打出一屏
警告，值还是没拿到。

这个别扭来自程序与资源的生命周期错位：程序几秒内执行完毕，资源在那之后才
创建——程序运行时值还不存在，只能先领一张"取货凭证"（Output），引擎兑现后再
回调。理解这张凭证的兑现规则，是写一切 Pulumi 程序的地基。

## What

**定义**：`Output<T>` 是"创建后才有值"的异步容器；`apply` 是唯一的提货窗口
（回调参数是解包后的普通值）；`pulumi.all` 把多个凭证凑成一单一起提。

| 部件 | 角色 |
|:---|:---|
| `Output<T>` | 资源创建后才有值的异步容器（`net.name`、`first.id`、`first.urn`） |
| `.apply(v => …)` | 提货窗口：v 在这里才是普通值；返回值仍是 Output |
| `pulumi.all([a, b])` | 多凭证聚合：`.apply(([va, vb]) => …)` 一次兑现 |
| `dependsOn: [r]` | 显式依赖：无数据引用也要排序时写进账本 |
| `propertyDependencies` | 账本字段：记录"哪个属性引用了哪个资源"的隐式依赖 |

可以把 Output 想象成取货凭证：下单（声明资源）时货没造好，凭证可以先转手、
可以先组合成大订单（`pulumi.all`），但**永远不能在提货窗口外拆开验货**。
失效边界：与真实凭证不同的是，引擎在窗口外"验货"不会报错中断——它只是警告
并把修复方法打在输出里，不看日志的人根本不知道自己拿到的是张白条。

![依赖图与取值边界](images/output_deep.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/08_output_deep/images/output_deep.html)（或本地打开 [`images/output_deep.html`](images/output_deep.html)）。

看图方法：左边程序声明资源；右侧是账本里的依赖图——实线是隐式属性依赖
（`networksAdvanced` 引用 `net`），虚线是显式 `dependsOn`（second 与 first
无数据引用，纯粹要排先后）。

## When to Use

- 组合多个资源的属性（拼 url、拼配置）：`pulumi.all` + `apply`；
- 两个资源没有数据引用、但有先后要求（先建配置再建消费方）：`dependsOn`；
- 排查"值没拿到"类问题：先看是不是在 apply 窗口外取的值。
- 反例：值在声明前就已知（配置、常量），直接用普通值，别包一层 Output。

| 取值写法 | 差异 | 什么时候选它 |
|:---|:---|:---|
| `.apply(v => …)` | 单 Output 取值 | 只有一个未来值要加工 |
| `pulumi.all` | ≥2 个 Output 聚合成一单 | 组合多个资源的属性 |
| `pulumi.interpolate` | 模板串语法糖，等同 all+apply | 纯字符串拼接场景 |
| 嵌套 apply | 功能等价但难读 | 别写；见到就改成 all |

## Quick Start

前置：Pulumi CLI、Node.js 22、Docker 运行中。

```bash
cd pulumi/08_output_deep
./output_deep.sh          # 完整生命周期：apply → graph → parallel → clean
./output_deep.sh apply    # 陷阱复现：顶层取值被拒，apply 里拿到真值
./output_deep.sh graph    # 从账本导出依赖图
./output_deep.sh parallel # --parallel 1 与默认并行对账
./output_deep.sh clean    # 销毁全清
```

`apply` 段的陷阱对照（真实输出，节选）：

```
[trap] 顶层直接取 first.id：Calling [toString] on an [Output<T>] is not supported.
    1: o.apply(v => `prefix${v}suffix`)
    2: pulumi.interpolate `prefix${v}suffix`
……（中间为两个容器的创建过程，略）
[ok] apply 里才拿得到值：first.id=3e0911688bc230b760a0fbe0bb3ae48c38912b979def030094238c2e848f9f69
```

同一份 `first.id`：顶层打印被引擎拒绝——两条修法一是 `.apply` 回调取值、二是
`pulumi.interpolate`（把 Output 直接拼进模板串的辅助函数，效果等同 all+apply）。
apply 回调里拿到的是真实容器 ID（每次 up 会变）。

`graph` 段从账本导出的依赖边（三行全列）：

```
docker:index/container:Container::first  --dependsOn-->  docker:index/container:Container::second
docker:index/network:Network::net  --dependsOn-->  docker:index/container:Container::first
docker:index/network:Network::net  --networksAdvanced-->  docker:index/container:Container::first
```

诚实预期：本实验只有 3 个 docker 资源，实测两种跑法 Duration 都是 5s——资源更多时
`--parallel 1` 才会明显变长；28601 被占用会在 curl 断言处报错。

stack（栈：同一程序的一次独立部署实例，各有一份账本）；`pulumi stack graph`
子命令在部分老版本不存在，本实验从 `stack export` 解析依赖边，等价且可断言。

## How It Works

### 依赖图：账本里的两本记录

`graph` 段解析 `stack export`，每个资源带两个依赖字段：`dependencies`（URN
〔Uniform Resource Name，每个资源在账本里的全局唯一名字〕级依赖，显式
dependsOn 与属性引用都会进）与 `propertyDependencies`（精确到属性）。

两条字段合看，三条边与代码一一对应：

```
net  --networksAdvanced-->  first   ← 隐式：first 的挂网属性引用了 net.name
net  --dependsOn-->  first        ← 属性引用同时会进 dependencies（引擎归并）
first  --dependsOn-->  second      ← 显式：second 无数据引用，纯业务顺序
```

`apply` 段实测 second 的创建行排在 first 之后——`--parallel` 再大，
dependsOn 也不让步。

### 顶层为什么拿不到值

程序执行时资源还没创建，`first.id` 只能是"壳"。顶层字符串模板取壳，引擎检测到
后打出 `Calling [toString] on an [Output<T>] is not supported`——注意这是**警告
不是异常**（官方输出写明未来版本**可能** throw），不看日志的人拿到的是张白条。

`pulumi.all([first.name, net.name]).apply(...)` 里拿到的则是普通值，导出的
`summary` 输出 `pulumi08-first @ pulumi08-net`。

### 并行度：只调速度，不改结果

`parallel` 段把同一期望态（期望态 = 代码声明的基础设施应该长成的样子）跑
两遍——`--parallel 1` 串行与默认并行——两次 `up` 后的账本逐项一致（脚本对
export 做了排序签名断言）。

期望态是一张依赖图，调度器按边约束自行排序：并行度影响的是速度不是结果——
本实验资源太少，两种跑法同为 5s，差距要在更大的依赖图上才显现。

## Pitfalls & Q&A

- **① 顶层误用只警告不报错**：`console.log(output)` 触发引擎警告但流程照走，
  值其实没拿到；装 `eslint-plugin-pulumi` 可以在写代码时就标红。
- **② 嵌套 apply 能跑但别写**：`a.apply(x => b.apply(y => …))` 语法合法、结果
  正确，但回调套回调可读性差；聚合两个以上 Output 一律 `pulumi.all`。
- **③ `--parallel` 不是正确性旋钮**：它不修复、也不破坏依赖；结果不对时先查
  依赖边缺失（该 dependsOn 的没写），别调并行度碰运气。

Q&A：

- **apply 里再 return 一个 Output 会怎样？** 引擎自动展开一层
  （`Output<Output<T>>` 会摊平），能跑；但类型签名难看，正解仍是 `pulumi.all`。
- **账本依赖与 URN 里的 `$` 是一回事吗？** 不是：`$` 是 parent（父子树，实验
  05），`dependencies`/`propertyDependencies` 是依赖图（本实验）——两个维度，
  账本里都查得到。
- **什么时候必须 dependsOn？** 两个资源无属性引用、但创建顺序影响结果时
  （例如"配置写入方"必须先于"配置读取方"）。有数据引用就不要再手写，
  隐式推断已经够了。
