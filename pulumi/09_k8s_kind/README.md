# 09 · Kubernetes Provider：同一模型，换一个 API

> 前八个实验用 Docker provider（Pulumi 对接各平台的驱动）把「声明期望态（用
> 代码描述系统最终该长什么样）→ 引擎（比对现实与期望态、补齐差异的核心）对账
> 收敛（把现实一步步改到与期望态一致）」跑熟了。本实验把目标 API 换成
> Kubernetes（容器编排平台，下文简称 K8s；跑在本机 kind 专用集群里）。
>
> Namespace + Deployment + Service 三件资源声明出来，改一行镜像配置再 `up`
> （Pulumi 真正创建/更新资源的主命令）就是滚动升级（新版实例逐个替换旧版，
> 服务不中断）；destroy（按账本把这套栈建过的资源全部删除）后集群零残留。零云：kind 单节点集群跑在 Docker 里。

## Background

生产环境的基础设施大多是 Kubernetes，而 01-08 号实验的容器只是"本机靶场"。
换工具（kubectl〔K8s 官方命令行〕+ 手写 YAML〔资源描述文件〕+ kustomize
〔在基础 YAML 上做差异化覆盖的官方工具〕）意味着丢掉已建立的期望态工作法。

Pulumi 的答案是把 Kubernetes 做成又一个 provider：程序、账本（state，引擎
维护的部署档案）、preview/up 回路（preview 只读地算变更，up 才执行）全部
原样，只有"翻译目标"从 Docker API 换成 K8s API。

本机没有真集群怎么办？kind（Kubernetes in Docker）用一个容器跑起单节点
集群。本实验建了专用集群 `pulumi-lab`，与机器上其他 kind 集群完全隔离。

## What

**定义**：`k8s.Provider` 是 Kubernetes 的方言翻译——程序里的期望态声明经它
翻译成 K8s API 调用；`context` 参数指定 kubeconfig（K8s 客户端共用的连接
配置文件，默认 `~/.kube/config`，每个集群一条 context 记录）里的哪个集群。

| 部件 | 角色 |
|:---|:---|
| `k8s.Provider({ context })` | 指向 kind 集群的连接；本实验所有资源都挂 `{ provider }` |
| `k8s.core.v1.Namespace` | 命名空间：本实验所有资源的隔离边界 |
| `k8s.apps.v1.Deployment` | 2 副本（replica：同时保持运行的两份相同实例）nginx；`spec.template` 变化即触发滚动升级 |
| `k8s.core.v1.Service` | ClusterIP（集群内部虚拟 IP）服务，按 label（键值对标签）选中一组 Pod（K8s 最小调度单元，包着一个或多个容器） |
| `kubectl rollout status` | 滚动升级的官方验收方式（脚本用它断言） |

可以把 provider 想象成外籍施工队附带的翻译：图纸（程序）还是那张图纸，翻译
把每条说明转成 Kubernetes 的术语递给 API。

失效边界：翻译不改变验收标准——K8s 的"完成"是 Pod Ready（比 Docker 的
running 严格），provider 会等副本真正就绪才记账，镜像拉不下来会等到超时
（见 Pitfalls ②）。

![同一模型，换一个 API](images/k8s_kind.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/09_k8s_kind/images/k8s_kind.html)（或本地打开 [`images/k8s_kind.html`](images/k8s_kind.html)）。

看图方法：程序声明期望态，经专用 provider 进入 kind 集群，扇出成三件资源；
provider 的 context 参数是"只管这个集群"的边界。

## When to Use

- 团队生产环境是 K8s：用 01-08 建立的期望态思维直接管集群资源；
- CI 里起临时验证环境：kind 集群 + Pulumi 栈（stack：同一程序的一套独立
  部署实例，自带配置与账本），跑完 destroy 零残留；
- 多集群治理：不同 provider 实例指向不同 context，一个程序管多个集群。
- 反例：只需要本机几个容器时，Docker provider 更轻——K8s 的抽象（副本、
  滚动、Service）在单机上是纯开销。

## Quick Start

前置：Pulumi CLI、Node.js 22、Docker、kind、kubectl。专用集群首跑自动创建
（`--image` 钉住本地 kindest/node 镜像，网络不好也能建）；k8s provider 插件
首次 `up` 自动安装（约 1 分钟）。

```bash
cd pulumi/09_k8s_kind
./k8s_kind.sh          # 完整生命周期：apply → rollout → clean
./k8s_kind.sh apply    # 专用集群上 up：Namespace + Deployment(2 副本) + Service
./k8s_kind.sh rollout  # 换镜像 tag（1.27 → 1.25）再 up：滚动升级
./k8s_kind.sh clean    # destroy 后 kubectl get all 零残留（集群保留）
```

`apply` 段的 kubectl 视角验收（真实输出）：

```
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   2/2     2            2           10s

NAME          TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
service/web   ClusterIP   10.96.145.43   <none>        80/TCP    10s
```

`rollout` 段只改配置里的镜像 tag（`pulumi config set imageTag 1.25`）再
`up`，`kubectl rollout status` 通过、部署镜像变为 `nginx:1.25-alpine`。

`clean` 段 destroy 后命名空间整体消失，`kubectl get namespace` 查无此 ns。

诚实预期：首跑要把两个 nginx 镜像装进 kind 节点（见 Pitfalls ①，脚本自动做）；
若跳过这步，Deployment 会等镜像拉取直到 10 分钟超时才失败；kind 集群保留
（可反复实验），彻底删除用 `kind delete cluster --name pulumi-lab`。

## How It Works

### provider 隔离：一个 context 一片天地

```ts
const provider = new k8s.Provider("kind", { context: "kind-pulumi-lab" });
const ns = new k8s.core.v1.Namespace("lab", { … }, { provider });
```

`~/.kube/config` 里可能有多个集群（本机实验时就有 6 个 kind 集群）；context
参数把本实验的读写范围钉在专用集群上，其余集群不碰。

三件资源全部显式挂 `{ provider }`——省略它会落到"当前 context"，换台机器就
可能写错地方。

### rollout：改配置即滚动升级

镜像 tag 走配置（`config.get("imageTag")`），`rollout` 段只做
`pulumi config set imageTag 1.25` + `up`——对引擎来说只是 Deployment 的
`spec.template` 变了。

对 K8s 来说 `spec.template` 一变就是新 ReplicaSet（按模板维持固定数量 Pod
的控制器，模板每变一次生成一个新版本）：新旧副本此消彼长，`kubectl rollout
status` 看着它完成。

控制面（哪些属性是"环境差异"）在程序里，滚动机制是 K8s 原生的。

### 离线镜像：kind 节点不共享宿主镜像

kind 集群的 containerd（节点容器里实际运行容器的运行时，相当于节点内部的
迷你 Docker）与宿主 Docker 不共享镜像库：宿主里的 nginx 镜像节点看不见，
节点自己去 docker.io 拉又赶不上网络。

脚本在 up 前把两个 tag 装进节点，Pod 的 `imagePullPolicy=IfNotPresent`
（非 latest tag 的默认值）就会直接用本地那份。

## Pitfalls & Q&A

- **① `kind load docker-image` 报 `ctr: content digest … not found`**：
  多架构镜像 tar 在 kind 节点导入会缺 content。正解：`docker save` 后用
  `ctr`（containerd 自带命令行）`images import` 直灌节点——保留原名，正好
  对上 Pod 的引用。
- **② 忘了装镜像 = 白等 10 分钟**：镜像拉不动时 Deployment 要等到
  `ProgressDeadlineExceeded`（默认 10 分钟）才失败，`up` 全程挂着。先装镜像
  再 up，失败循环在秒级结束。
- **③ 建集群钉住本地镜像**：`kind create cluster --image
  kindest/node:v1.36.1` 用本地已有的节点镜像，否则 kind 默认拉 latest，
  网络差时集群都建不起来。

Q&A：

- **为什么用专用集群？** kind 集群是本机共享资源（本机实验时另有 5 个），
  专用集群保证 destroy 不会波及别人的东西；context 隔离 + 集群隔离双保险。
- **滚动升级是谁触发的？** 是 K8s 原生机制：Deployment 的 `spec.template`
  变化产生新 ReplicaSet。Pulumi 只负责把新期望态送到 API——分工与实验 03
  的"引擎管收敛、provider 管翻译"一脉相承。
- **clean 为什么不删集群？** 集群是可复用的实验底座（同 labs/05 的靶场
  思路），删资源不删底座；要回收磁盘再手动 `kind delete cluster`。
