# 11 · ⛓️ 多 Provider 混合编排：一张账本，三个世界

> LocalStack S3 里的"远端配置"，经 Output 跨 provider 流进 kind 集群的
> ConfigMap（K8s 存配置键值对的对象），再注入 Pod（K8s 最小部署单元，内含
> 容器）环境；宿主的 edge 容器用 dependsOn（显式依赖声明：强制排在指定资源
> 之后）垫底。
>
> 一次 `up` 建成三个世界——aws、kubernetes、docker 三种资源记在同一本账里，
> 跨 provider 的依赖边在 `stack export` 里清清楚楚。

## Background

09、10 号实验分别接过 Kubernetes 与 AWS 的 provider，但每次只用一个。真实的
系统很少只住在一个世界里：配置放对象存储、应用跑在集群、边缘工具躺在宿主——
三者的启动顺序还互相牵制（配置没就绪，消费方起了也白起）。

分开建（三个项目、三次 up）要人肉编排顺序；Pulumi 的答案是 provider 可以在
同一个程序里混用——栈（同一程序的部署实例）是唯一的账本，三个世界的资源、
跨世界的依赖，全部记在一起。

## What

**定义**：多 Provider 编排是在同一个栈里实例化多个 provider（Pulumi 的平台
插件：把资源声明翻译成对应平台的 API 调用），各连各的世界。

资源之间的 Output（Pulumi 的值占位符：资源建好后才确定的值，一方引用另一方
的 Output 即自动声明依赖）流动与 dependsOn 不分 provider——引擎把三个世界
画进同一张依赖图，照图排序执行。

| 部件 | 本实验的角色 |
|:---|:---|
| `aws.Provider` | 连 LocalStack（在本机 Docker 里模拟 AWS 云 API 的仿真器，S3
  请求实际发往 localhost:4566）：S3 桶 + "远端配置"对象（消息源） |
| `k8s.Provider` | 连 kind 集群（kind：Kubernetes-in-Docker，用 Docker 容器
  在本机跑 K8s 集群的工具）：ConfigMap（收下消息）+ Deployment（注入 Pod） |
| docker 默认 provider | 连宿主 daemon：edge 观测容器（垫底起） |
| `payload.content → cm.data` | 跨 provider 的 Output 流动——隐式依赖跨世界生效 |
| `dependsOn: [deploy]` | 跨 provider 的显式顺序——edge 最后起 |

可以把三个 provider 想象成同一位包工头手下的三支施工队（云上队、集群队、
宿主队）：施工单（栈）只有一份，队与队之间的工序衔接写在同一张进度图上，
谁先谁后图说了算。失效边界：施工队各自要能开工——kind 集群与 LocalStack
这两个底座得先在（本实验复用 09/10 号留下的，脚本探活、缺了才建）。

![一张账本，三个世界](images/multi_provider.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/11_multi_provider/images/multi_provider.html)（或本地打开 [`images/multi_provider.html`](images/multi_provider.html)）。

看图方法：三个橙虚线区域就是三个世界；绿实线是跨 provider 的数据流
（S3 → ConfigMap），两条虚线是顺序约束（ConfigMap → Deployment 注入、
Deployment → edge 垫底）。

## When to Use

- 系统天然跨世界：云上配置 + 集群应用 + 宿主工具，要一次声明、一次收敛；
- 迁移期共存：旧服务还在 Docker、新服务已上集群，过渡期同栈管理；
- 多环境粘合：LocalStack 的"云"、kind 的集群、宿主的观测端，一套程序全拉起。
- 反例：各世界本就独立变更节奏时，硬合成一个栈会让 blast radius（波及范围）
  变大——改一行边缘配置也要过整个栈的 diff。

## Quick Start

前置：Pulumi CLI、Node.js 22、Docker、kind 与 LocalStack CLI，以及脚本验收
要用的 `aws`、`kubectl` 与 python3（macOS 一条命令装齐：
`brew install awscli kubectl python3`）。

两个底座（09 号的 kind 集群、10 号的 LocalStack）已存在则直接复用，缺了
自动补建。

```bash
cd pulumi/11_multi_provider
./multi_provider.sh          # 完整生命周期：apply → graph → clean
./multi_provider.sh apply    # 一次 up（Pulumi 的部署命令）跨三 provider，断言顺序与三视角
./multi_provider.sh graph    # 从账本导出跨 provider 依赖边
./multi_provider.sh clean    # destroy（Pulumi 的拆除命令）后三世界零残留（底座保留）
```

`apply` 段的顺序断言与三视角验收（真实输出，节选）：

```
        [ok] 行 37 aws 创建 → 行 41 k8s 创建：跨 provider 的 Output 流动兑现
        [aws] 2026-10-16 11:25:03 pulumi11-payload
        [k8s] deployment.apps/app   1/1   1     1     1s
        [docker] pulumi11-edge  0.0.0.0:28701->80/tcp
        [ok] S3 的消息已流进 ConfigMap 并注入 Pod 环境（MESSAGE）
```

`graph` 段从账本里导出的跨 provider 依赖边（节选）：

```
[aws] …:BucketObject::config-message --data--> [kubernetes] …:ConfigMap::app-config
[kubernetes] …:Deployment::app --dependsOn--> [docker] …:Container::edge
```

诚实预期：首跑装依赖与 aws 插件（若 10 号实验装过则秒回）；Pod 里的 MESSAGE
用 `kubectl exec … printenv` 验证，值就是 S3 对象的内容；`clean` 只清三个
世界的资源，kind 集群与 LocalStack 留作底座。

## How It Works

### 跨 provider 的 Output 流动：隐式依赖不分世界

```ts
const cm = new k8s.core.v1.ConfigMap("app-config", {
    metadata: { name: "app-config", namespace: "pulumi11-lab" },
    data: { message: payload.content.apply((c) => c ?? "") },
}, { provider: k8sProvider, dependsOn: [ns] });
```

`payload`（AWS 世界）的 `content` 流进 `cm`（K8s 世界）的 `data`——这只是一个
普通的属性引用，引擎照例在账本记下 `propertyDependencies`，排序时自然先
S3 后 ConfigMap。up 日志实测：aws 创建行在第 37 行、k8s 创建行在第 41 行。

### 显式顺序：edge 与谁都没数据关系

edge 容器不引用任何 Output，但要求"集群部署完再起"——`dependsOn: [deploy]`
把这条业务顺序写进账本 `dependencies`。

export 里能看到它跨了世界：
`kubernetes:apps/v1:Deployment::app --dependsOn--> docker:…:Container::edge`。

### 同栈清点：三类资源前缀

`graph` 段按类型前缀给账本清点：`aws:` 2 条、`kubernetes:` 3 条、`docker:`
1 条——同一本账、同一个 URN（Pulumi 给每个资源起的统一全名，形如
`aws:s3/bucket:Bucket::payload-src`）命名空间。

destroy 也按这本账逆序拆除，三个世界一起清干净（脚本三视角分别断言零残留）。

## Pitfalls & Q&A

- **① 可选属性要兜底**：`BucketObject.content` 的类型是
  `Output<string | undefined>`，直接喂给要 `Input<string>` 的属性会报
  TS2322（TypeScript 的类型不匹配编译错误）；
  `.apply((c) => c ?? "")` 兜底。
- **② 账本 grep 用显示名**：up 日志里 AWS 资源显示为 `aws:s3:BucketObject`
  （简化形态），完整 URN 是 `aws:s3/bucketObject:BucketObject`——按显示名
  grep 日志、按 URN 解析 export，别混。
- **③ provider 启动期的隐式调用**：aws provider 初始化会调 STS（AWS 签发临时
  凭证的服务）与 IAM（AWS 的身份与权限服务），
  endpoints 必须把这两个服务也指向 LocalStack（实验 10 的教训在本实验直接复用）。

Q&A：

- **跨 provider 的依赖怎么执行？** 与同 provider 无异：引擎只有一张全局依赖
  图，边跨不跨世界不影响排序——本实验的 up 日志顺序就是证明。
- **destroy 的顺序也是图定的吗？** 是：按账本依赖逆序拆除，三个世界一起清；
  底座（kind 集群、LocalStack 本身）不是栈内资源，不在拆除范围。
- **三个世界能拆成三个栈吗？** 能，代价是跨栈传递要靠 `stack export` 或
  远端状态查询；同栈的收益正是本实验的跨世界依赖自动排序——拆不拆取决于
  变更节奏是否一致。
