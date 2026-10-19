# 11 · 滚动更新与健康门禁（kind 上）

> 滚动更新 = 副本（同一服务的多个等价容器实例）逐个替换：新副本**先起来、
> 过探针、接流量**，旧副本才允许下线；readinessProbe 就是健康门禁——探针
> 不过的副本不进 endpoints（Service 的可用后端列表），一个请求都分不到它。
>
> 本实验在 kind 集群上跑三副本 Deployment：好版本滚动期间 19.7 万请求
> 0 失败；注入坏镜像看门禁拦截；再 `rollout undo` 一键回退。

## Background

09/10 的蓝绿与金丝雀都工作在"整套环境"粒度——双槽意味着资源翻倍。k8s
滚动更新把粒度做到"单个副本"：边起新边删旧，资源平缓、全程在同一个
Deployment 里完成。

但"新副本进程起来了"不等于"它能服务"。没有健康门禁的滚动更新等于盲换
轮胎：坏副本一旦被放进 endpoints，真实流量立刻替它陪葬。readinessProbe
把"能不能接流量"变成一个可验证的探活问题，坏版本连门都进不去。

## What

**定义**：滚动更新 = `strategy: RollingUpdate` 控制下的逐副本替换；
健康门禁 = `readinessProbe` 决定副本是否进入 Service endpoints。

| 参数 | 作用 | 本实验实测 |
|:---|:---|:---|
| `maxUnavailable: 0` | 可用副本永不低于 3，容量不降 | 197,674 请求 0 失败 |
| `maxSurge: 1` | 先多起 1 个新副本（先加后减） | 活跃副本 3→4 交替；滚动完成瞬间含收尾副本实测 5×1/1 |
| `readinessProbe` | 探针不过 → 不进 endpoints | 坏副本 0/1，endpoints 保持 3 个 IP |
| `progressDeadlineSeconds: 30` | 卡住的更新 30s 判死 | `rollout status` 快速非零退出 |

可以把滚动更新想成"行进中逐个换胎"：蓝绿是备好一辆整车整体替换，金丝雀
是让部分乘客先坐新车；滚动则是每个新胎装上后先充气检查（探针），合格才
承载，不合格原地卸下，全程车辆不停驶。

失效边界：类比没覆盖"被卸下的旧胎"——旧副本被删除的瞬间若不做排水，
在途与新到的连接会被直接 RST（本实验首跑实证，见 Pitfalls ①），所以
零停机还需要 `preStop` 排水窗口。

![滚动更新与健康门禁](images/rollout_gate.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/11_rollout_gate/images/rollout_gate.html)（或本地打开 [`images/rollout_gate.html`](images/rollout_gate.html)）。

看图方法：上行为数据面（压测 → Service → 新旧副本），下行为控制面
（探针 → Deployment 控制器 ← rollout undo）——控制器保证"新的 Ready
才删旧的"，探针保证"没 Ready 的不接流量"。

## When to Use

- k8s 上发布无状态多副本服务的默认姿势：资源平缓、全程在线；
- 配合 readinessProbe 天然形成健康门禁：坏版本自动被拦在流量之外；
- 反例：单副本服务（`maxSurge` 也保不住容量窗口）、新旧版本共享状态
  不兼容（schema 变更）、副本需要独占 PV 挂载——这些场景滚动会翻车。

## Quick Start

前置：Docker、kind（`brew install kind`）、kubectl（`brew install
kubectl`）；nginx:1.27/1.25-alpine 基础镜像本地已有。诚实预期：kind 首跑
要拉约 1GB 的 kindest/node 节点镜像——第一次不算离线，之后集群增删全离线。

```bash
cd cicd/11_rollout_gate
./rollout_gate.sh           # 完整生命周期：up → good → bad → undo → clean
./rollout_gate.sh up        # 起 kind 集群 + 三版本镜像 + v1 三副本
./rollout_gate.sh good      # 好版本滚动更新：压测中滚动，断言 0 失败
./rollout_gate.sh bad       # 坏版本：探针拦截，rollout 卡住、坏副本不接流量
./rollout_gate.sh undo      # 回退到上一个好版本
./rollout_gate.sh clean     # 删集群，还原 kubectl context
```

`good` 段的真机取证（完整输出见脚本运行日志）：

```
        [ok] 滚动全程压测 197674 请求，Failed requests: 0（maxUnavailable 0：容量永不下降）
        [ok] 采样时间线：v1 × 42 → v2 × 64，无空窗无 5xx（0 个异常）
        [ok] 更新后 200 请求全量 v2
```

`bad` 段（坏版本被 readiness 拦截）：

```
        [ok] rollout status 非零退出：progressDeadlineSeconds 30s 判定进展停滞
        [ok] 副本状态：1/1 × 3、0/1 × 1——旧副本 3 个继续服务，坏副本卡在 Ready 门外
        [ok] Service endpoints 仅 3 个 IP——readiness 不过 = 不进 endpoints = 不接流量
        [ok] 卡住期间 100 请求全量 v2、零 500——用户完全无感
```

诚实预期：197,674、42→64 等数字每次运行都会变；断言的不变式是"0 失败"、
"坏副本 0/1 且 endpoints 不变"、"undo 回到上一个版本"。

## How It Works

### 滚动时序：先加后减，Ready 才接班

`set image` 后控制器按 `maxSurge: 1` 先起新副本；探活通过 → Ready → 进
endpoints 接流量 → 控制器才删一个旧副本。删旧前先执行 `preStop`（睡 3s，
等摘除信息传播）再收 SIGTERM。采样时间线 v1 × 42 → v2 × 64 就是逐副本
交接，全程无空窗。

### 坏版本拦截：探针不过 = 流量之外

坏镜像把 `/version` 改成 500——探针打的就是这个路径，新副本永远 0/1。
k8s 很克制：坏副本留着反复探测，但**不进 endpoints、不接流量、不自动
回滚**；30s 到点标记 `ProgressDeadlineExceeded`——处置（修或回滚）是
人的决定。

### 回滚语义：undo 只退一步

`rollout undo` 把模板回退到**上一个 revision**（revision = 模板每次变更
时 k8s 自动留存的版本快照）——本实验紧跟 good 之后，所以回到的是 v2
而不是 v1（实测恢复后 200 请求全量 v2）。回滚也是一次滚动更新：模板
变了，副本逐个滚回去，同样受探针保护。

### 为什么压测敢说 0 失败

压测打的是宿主机 29090（kind 映射到 NodePort 30080）：
只要 endpoints 始终有 Ready 副本、终止中的副本不 RST 连接，客户端就
感觉不到任何断连。197,674 个请求横跨滚动全程，`Failed requests: 0`
直接度量了"容量不降 + 优雅交接"。

## Pitfalls & Q&A

- **① 没有 preStop，终止副本直接 RST 连接**：开发期第一版（无 preStop）
  压测在滚动中被 `apr_socket_recv: Connection reset by peer (54)` 打断，
  51,407 个请求后 ab 整场中止。endpoints 摘除传到 iptables 有窗口期，窗口
  内新连接仍会落到终止中的副本上——`preStop: sleep 3` 让它们照常被服务。
- **② apply 后首个突发可能空响应**：extraPortMappings/conntrack 冷启动
  期间偶发超时——基线断言前先打 50 个请求预热再断言。
- **③ `terminationGracePeriodSeconds` 是 Pod 级字段**：写进 container 里
  会 `strict decoding error: unknown field`；它属于 `spec.template.spec`。
- **④ rollout status 成功 ≠ 集群安静**：被替换的副本还在 Terminating
  （0/1 收尾中，最长约 15s），此时 `get pods` 仍能看到它——不是异常。

Q&A：

- **滚动 vs 蓝绿/金丝雀怎么选？** 滚动：资源平缓、k8s 原生，但流量粒度
  只能到副本、回滚速度取决于副本数；蓝绿：整套切换、回滚最快、资源翻倍；
  金丝雀：真实流量分档验证。生产常见组合是"金丝雀门禁 + 滚动放量"。
- **k8s 会自动回滚失败的更新吗？** 不会。`ProgressDeadlineExceeded` 只是
  一个标记，坏副本会一直被反复探测——止血必须人来执行 `rollout undo`。
  这是有意的：平台不替你判断"回滚"和"修复"哪个对。
- **readiness 和 liveness 探针有什么区别？** readiness 决定"接不接流量"
  （不进 endpoints），失败只摘流量；liveness 决定"要不要重启容器"，失败
  会杀进程。坏版本拦截靠 readiness，用 liveness 拦坏版本只会陷入重启循环。
