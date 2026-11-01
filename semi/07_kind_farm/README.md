# 07 · kind 弹性农场：K8s executor 与队列模拟

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 7 · 阶段二「Runner 农场与执行环境」收官
> kind 单节点集群跑 GitLab Runner K8s executor：每 job 一 Pod、低资源限额、Pending 队列观测
> 验收①②在 `kind_farm.sh verify`：Pod 内执行证据 / 4 job 撞并发 2 的 Pending 观测累计 ≥2

## Background

半导体大厂的计算农场本质是 K8s：EDA 仿真容器化后按 Pod 调度，空闲算力自动回收。

项目 5 的 docker executor 是"runner 自己造容器"，K8s executor 则把调度交给集群——

runner 只提交 Pod 请求。

本实验用 kind（Kubernetes in Docker）单节点集群验证这条路径：runner 以 **Pod 形态**住进集群，job 也以 Pod 形态执行。

## What

心智模型一句话：**runner 变成 Pod，job 也变成 Pod——农场只剩一种"动物"**。

```
GitLab(宿主 28200) ←── runner-k8s Pod（K8s executor，concurrent=2）
                          │ 每 job 创建
                          ▼
                    job Pod（alpine，cpu/mem 限额 100m/128Mi）
```

关键接线：Pod 回连宿主 GitLab 用 **Mac 局域网 IP**（`http://<IP>:28200/`）——Pod 网络经节点 NAT 出去，`localhost`/compose 网络别名都不可达。

验证方法：`./kind_farm.sh status` 看节点与 Pod，`./kind_farm.sh verify` 跑两条断言。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 算力池化 + 弹性伸缩（生产形态） | K8s executor（本实验）；生产再叠加 autoscaler |
| 低资源 job 的公平排队 | 每 Pod resource limits（本实验 100m/128Mi）——超限即 Pending |
| 只想快速验证 CI 逻辑 | docker executor（项目 5）更省事；K8s 链路长，生产才值得 |
| 集群内已有任务队列（Slurm 等） | K8s executor 管 CI 编排，HPC 队列对接见项目 15 |

## Quick Start

前置：项目 5/6 完成；`brew install kubectl`；kind 节点镜像与 runner 镜像走 daocloud。

```bash
./kind_farm.sh up      # 建集群（首次 ~2 分钟）→ ctr 预载 runner 镜像 → 部署 runner Pod → 加 4 个 k8s job
./kind_farm.sh verify  # 两条断言
./kind_farm.sh status  # 集群/Pod 现状
./kind_farm.sh clean   # 删集群（runner-lab 的 job 定义保留）
```

`verify` 的真实输出（实测，两条全过）：

```
=====> [verify] 验收① k8s job 在 Pod 内执行
  [ok]   k8s-1 在 Pod runner-o6r4rkcub-project-11-concurrent-0-q9i5qpkr 内执行（hostname 证据）
=====> [verify] 验收② Pending 观测累计 ≥2
  [ok]   观测到 10 次 Pod Pending（并发 2 撞上 4 个 job）

[ok] 项目 7 全部验收断言通过
```

诚实预期：Pending 观测值是「每秒轮询到的 Pending Pod 数累计」，量级随调度速度波动（实测 9-121 次）；①的 job Pod 名是 `runner-<tokenhash>-project-N-concurrent-X`——**与 runner Pod（runner-k8s-*）是两种东西**。

## How It Works

### 部署三件套：ConfigMap + RBAC + Deployment

runner 以声明式清单进集群：config.toml 挂进 ConfigMap。

渲染时把 toml 统一缩进 4 格对齐块标量，且占位符行本身缩进要归零——否则首行 8 格 vs 后行 4 格直接 YAML 解析崩。

**RBAC 必配**：Role 授权 pods/secrets/configmaps 增删改查，否则 job 卡在 `secrets is forbidden`。

Deployment 挂载到 `/etc/gitlab-runner`（默认配置路径，挂到 home 会报 config not found）。

### 镜像供给：预载 + helper

节点拉不动外网镜像：registry.gitlab.com 被墙，kind load 又对多架构镜像报 digest 缺损。

runner/helper 镜像用 `docker save | ctr --namespace=k8s.io images import -` 直导入节点。

**helper 镜像**（每 job Pod 都要拉）再在 config 里显式 `helper_image` 指向 daocloud 版本——不配它，job 全部卡在 `prepare environment: pulling image gitlab-runner-helper`。

### 队列语义：Pending 即排队

concurrent=2 + 4 个 job → 第 3、4 个 Pod 进入 Pending，直到空位。

观测脚本每秒数 `--field-selector=status.phase=Pending` 的 Pod 累计——**K8s 的 Pending 是公开状态**，比 docker executor 的"runner 内部队列"透明得多，这正是生产农场用 K8s 的可观测性红利。

## Pitfalls & Q&A

**坑 1：K8s executor 的 job Pod 卡 `prepare environment`。** 九成是 helper 镜像拉不下来（默认 registry.gitlab.com）。

`helper_image` 显式指国内源 + ctr 预载，tag 要带架构前缀（arm64-v19.5.2）且与 runner 版本一致。

**坑 2：runner Pod 起来了但 `Checking for jobs... forbidden`。** 多半是旧 Pod 还在用被吊销的 token（每次 up 会重签）；等 rollout 完成即自愈。另配好 RBAC，否则下一层报 `secrets is forbidden`。

**坑 3：kind load 报 `content digest not found`。** 多架构镜像带 attestation 清单，或宿主镜像层缺损（OrbStack 僵死重启后见过）。

绕行：`docker save | ctr import`，并显式 `--platform=linux/arm64` 重拉。

**Q：Pod 怎么回连宿主上的 GitLab？** Pod → 节点 → NAT → 宿主。compose 网络别名（http://gitlab/）在 Pod 网络不生效，用 Mac 局域网 IP（`ipconfig getifaddr en0`）注入 clone_url。IP 变了重跑 up。

**Q：内存配置为什么动过？** OrbStack VM 实际内存默认 16G（不是宿主 64G）——GitLab + kind + 其他系列集群同住会 OOM 整机僵死（实测两次）。

本系列用 `orbctl config set memory_mib` 调过 32G 又按需回落；日常启停用 `semi/ctl.sh`（一键启停本系列 5 个容器，OrbStack UI 分组标签 dev.orbstack.group=semi-cicd）。

**Q：验收②观测数为什么波动大？** 每秒采样 × Pod 存活时长，调度越快累计越小；断言只设 ≥2 下限，方向比数值重要。