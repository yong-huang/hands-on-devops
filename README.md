# hands-on-devops

一条完整 DevOps 流水线的搭建与演练：**IaC → 配置管理 → 镜像/制品 → CI/CD → GitOps/策略 → 可观测/漂移**
覆盖 Terraform · Ansible · Molecule · Salt · Chef · Puppet · Packer · Woodpecker · Gitea Actions ·
Prometheus/Loki/Grafana · SOPS/Vault · cosign/syft 等工具链。
**零云依赖**：Docker 容器当被管节点（"靶场环境"），macOS 本机全部可跑、全部免费。

> 配套清单：`docs/devops.md`（30 项目 · 6 阶段 · 每项目带验收标准与 AI 提示词）
> 进阶系列：`docs/cicd.md`（CI/CD 进阶 16 项目 · GitHub Actions 为轴 · 实验在 `cicd/` 目录）
> 互补线：`docs/pulumi.md`（Pulumi 快速上手 12 项目 · TS 主线 + Python 对照 · Docker/kind/LocalStack 三 Provider 零云）
> 安全线：`docs/devsecops.md`（DevSecOps 安全纵深 30 项目 · 本机零云攻防靶场）

## 环境要求

- **Docker**（Docker Desktop 或 OrbStack；macOS/Linux 均可）
- **Terraform ≥ 1.6** + **Ansible ≥ 2.15** + **Python 3.10+**
- 按阶段补充：tflint · packer · syft · cosign · sops · age · kubectl · kind 等
  （各实验 README 均标注了安装命令）

## 快速开始

```bash
# 靶场环境（实验 05 提供，后续实验共用）
make lab-up
make lab-status

# 任选实验，cd 进去跑主脚本
cd labs/01_tf_docker_provider && ./tf_docker_provider.sh
cd labs/06_ansible_role_vault && ./ansible_role_vault.sh
```


## 宿主端口分配表

全系列（含与 hands-on-mlops 等相邻系列）错峰分配。**新实验一律从表内
空闲段取号**，改端口前先对照本表——端口冲突曾造成多次发布实验失败。

| 端口段 | 归属 | 说明 |
|:---|:---|:---|
| 28080 | 实验 01 | tf01-nginx（文档标准端口） |
| 28081 / 28082 | 实验 02 | 蓝 / 绿 |
| 28085 | 实验 05 长驻靶场 nginx | labs 06+ 依赖，长期在线 |
| 28090-28095 | 实验 04 | ws-dev / ws-staging×2 / dir-dev / dir-staging×2 |
| 3350 / 3351 / 3352 | 实验 16 / 17 / 18 | Jenkins / Jenkins / Gitea Actions |
| 3300 | 靶场 Gitea | labs 06+ 复用 |
| 5000 / 5500 / 5550 | 靶场与实验 11-15 | registry（实验间按序复用） |
| 9100 / 9101 | 实验 05 长驻 MinIO | labs 06+ 依赖 |
| 9200 / 9201 | 实验 03 一次性 MinIO | 即起即删 |
| 90xx | hands-on-mlops | 相邻系列，永久错峰 |
| 18090 | hands-on-cicd 项目 09/10 | 相邻系列蓝绿/金丝雀 |

## 实验列表

| 编号 | 实验 | 工具 | 状态 |
|:---|:---|:---|:---|
| 01 | Docker Provider——用 TF 管容器 | Terraform | ✅ 真机验证 |
| 02 | 模块化 + 本地 Registry 引用 | Terraform | ✅ |
| 03 | 状态管理深潜 | TF + MinIO | ✅ |
| 04 | 多环境矩阵 | Terraform | ✅ |
| 05 | 集成点①：靶场环境 | TF | ✅ |
| 06 | Ansible 深水区 | Ansible | ✅ |
| 07 | Molecule——给 Role 写测试 | Molecule | ✅ |
| 08 | Salt masterless | Salt | ✅ |
| 09 | Chef 本地模式 + InSpec | Chef/InSpec | ✅ |
| 10 | Puppet（探活 + 降级） | Puppet | ✅ |
| 11 | 镜像瘦身与多架构 | Docker/buildx | ✅ |
| 12 | Packer 镜像流水线 | Packer | ✅ |
| 13 | Registry 治理 | registry:2 | ✅ |
| 14 | SBOM + 签名 | syft/cosign | ✅ |
| 15 | 集成点②：手工发布流水线 | Make/cosign | ✅ |
| 16 | Jenkins 基础 | Jenkins | ✅ |
| 17 | Jenkins 深水区 | Jenkins | ✅ |
| 18 | Gitea + Actions | Gitea Actions | ✅ |
| 19 | Woodpecker（⚠️ 兼容性诊断） | Woodpecker | ⚠️ 部分验证 |
| 20 | 完整 CI/CD | Gitea Actions | ✅ |
| 21 | Flux GitOps | Flux | ⬜ |
| 22 | 策略即代码（OPA） | OPA/Conftest | ⬜ |
| 23 | IaC 安全扫描 | tfsec/trivy | ⬜ |
| 24 | 密钥治理 | SOPS/age | ⬜ |
| 25 | 集成点③：合规流水线 | — | ⬜ |
| 26 | 监控栈 | Prometheus/Grafana | ⬜ |
| 27 | 集中日志 | Loki | ⬜ |
| 28 | 配置漂移检测与治理 | TF/Ansible | ⬜ |
| 29 | 备份与灾难恢复 | — | ⬜ |
| 30 | 终极串联——DevOps 一体机 | 全部 | ⬜ |

## CI/CD 进阶系列（cicd/）

devops.md 的互补进阶线：**GitHub Actions 为轴**，本机 act 离线迭代 + 真仓库免费额度，
不与 labs/ 01-30 重复（关系对照见 `docs/cicd.md` 文末）。清单：`docs/cicd.md`。

| 编号 | 实验 | 工具 | 状态 |
|:---|:---|:---|:---|
| 01 | act 本地回路与 workflow 语法深潜 | act | ✅ 真机验证 |
| 02 | 矩阵构建与并发治理 | Actions ☁️ | ✅ 真机验证 |
| 03 | 可复用工作流与复合动作 | Actions | ✅ 真机验证 |
| 04 | 缓存与构建加速 | Actions/buildx | ✅ 真机验证 |
| 05 | self-hosted runner 与标签路由 | Actions ☁️ | ⬜ |
| 06 | Environments 部署保护与审批流 | Actions ☁️ | ✅ 真机验证 |
| 07 | OIDC 短时凭据 | Actions ☁️ | ✅ 真机验证 |
| 08 | 流水线供应链加固 | Actions ☁️ | ✅ 真机验证 |
| 09 | 蓝绿部署 | Compose/nginx | ✅ 真机验证 |
| 10 | 金丝雀发布与指标门禁 | nginx | ✅ 真机验证 |
| 11 | 滚动更新与健康门禁 | kind | ✅ 真机验证 |
| 12 | 版本账本与一键回滚 | Docker/nginx | ✅ 真机验证 |
| 13 | monorepo 增量构建 | Actions | ✅ 真机验证 |
| 14 | flaky test 治理 | pytest | ✅ 真机验证 |
| 15 | semantic-release 版本工程 | Actions ☁️ | ✅ 真机验证 |
| 16 | 🏁 终极串联：生产级发布系统 | 全部 ☁️ | ✅ 真机验证 |

> ☁️ = 需推送 GitHub 真仓库（公共仓库免费）；其余纯本机可跑。

## Pulumi 互补线（pulumi/）

devops.md 的互补线：IaC 的「通用编程语言」视角，与 labs/ 01-05 的 Terraform 同题对照
（关系对照见 `docs/pulumi.md` 文末）。清单：`docs/pulumi.md`。

| 编号 | 实验 | Provider/工具 | 状态 |
|:---|:---|:---|:---|
| 01 | 第一个程序——Docker Provider 与 CLI 回路 | Docker | ✅ 真机验证 |
| 02 | 编程语言的力量——循环/条件/函数 vs HCL | Docker | ✅ 真机验证 |
| 03 | Stack 与配置——多环境 + Secrets | Docker | ✅ 真机验证 |
| 04 | 状态管理——本地文件 → MinIO S3 后端 | MinIO | ✅ 真机验证 |
| 05 | ComponentResource——对标 TF module | Docker | ✅ 真机验证 |
| 06 | 给 IaC 写测试——Mocks 单测 + Policy 拦截 | CrossGuard | ✅ 真机验证 |
| 07 | Python 对照——同题重写 | Python SDK | ✅ 真机验证 |
| 08 | Output 编程模型深水区——apply 陷阱与依赖图 | Docker | ✅ 真机验证 |
| 09 | Kubernetes Provider——kind 部署应用 | kind | ✅ 真机验证 |
| 10 | AWS Provider——LocalStack 上管云资源 | LocalStack | ✅ 真机验证 |
| 11 | ⛓️ 多 Provider 混合编排——一次跨三栈 | 三栈 | ✅ 真机验证 |
| 12 | 🏁 交付闭环——preview 门禁进 CI | 全部 | ✅ 真机验证 |

> 零云：Docker + kind + LocalStack 全本机免费；TypeScript 主线，项目 7 用 Python 对照。**12/12 全部完成（2026-10-15）**。

## 目录结构

```
hands-on-devops/
├── README.md                        # 本文件
├── docs/
│   ├── devops.md                    # DevOps 主线 30 项目清单
│   ├── cicd.md                      # CI/CD 进阶 16 项目清单
│   └── pulumi.md                    # Pulumi 快速上手 12 项目清单（互补线）
├── Makefile                         # 统一入口（lab-up / lab-down / demo）
├── scripts/
│   ├── load_resources.sh            # 镜像预载（含 daocloud 回源）
│   ├── tfrc.sh                      # Terraform provider 离线镜像
│   ├── docker-env.sh                # Docker socket 自动探测（默认 OrbStack 优先）
│   └── tf-mirror/                   # kreuzwerker/docker provider 离线包
├── labs/                            # DevOps 主线（01-30，编号与 devops.md 对应）
│   └── NN_short_name/
│       ├── README.md                # 8 节教程（为什么→图→快速开始→概念→字段→结构→深入→总结）
│       ├── xxx.sh                   # 主演示脚本（apply/observe/.../clean 全真机验证）
│       ├── configs/ 或 manifest     # 声明式配置（注释密度远高于生产）
│       └── images/
│           ├── xxx.sequence.json    # 图源（typed JSON IR，可用配套工具重新渲染）
│           ├── xxx.html             # 交互版（自包含单文件）
│           └── xxx.svg              # 双主题矢量图（README 内嵌）
├── cicd/                            # CI/CD 进阶线（01-16，编号与 cicd.md 项目号 1:1 对应）
│   └── NN_short_name/               # 结构与 labs/ 一致；声明式配置按领域取名为 workflows/ 等
└── pulumi/                          # Pulumi 互补线（01-12，编号与 pulumi.md 项目号 1:1 对应）
    └── NN_short_name/               # README 六段式 + 主脚本 + program/（TS 程序）+ images 图三件套
```

## 每实验脚本约定

```bash
./xxx.sh            # 完整生命周期（创建 → 观察 → 破坏 → 验证 → 清理）
./xxx.sh apply      # 只创建
./xxx.sh observe    # 只观察
./xxx.sh clean      # 只销毁（零残留断言）
```

所有脚本 `cd "$(dirname "$0")"` 保证任意 cwd 可跑；等待用轮询而非裸 sleep；
清理后有容器/网络/卷三重断言。

## 排障与已知问题

- **GitHub 不可达**：Terraform provider 走仓库内离线镜像（`scripts/tfrc.sh`）；
  Docker 镜像自动回源 daocloud（`scripts/load_resources.sh`）
- **Docker socket**：`scripts/docker-env.sh` 自动探测并导出 `DOCKER_HOST`
  （Go/SDK 客户端不认 docker context）；默认 OrbStack 优先，`DOCKERDESKTOP=1` 切回
- **实验 19 Woodpecker**：SPA 会话 + webhook 触发在 macOS HTTP 环境受限，
  完整诊断见其 README §7

## 学习路线

建议按 6 阶段顺序推进（每阶段 5 实验，每天 2-3 小时，全系列 8-9 周）：

1. **IaC 深水区**（01-05）：Terraform 资源→模块→状态→多环境→靶场
2. **配置管理四大代际**（06-10）：Ansible→Molecule→Salt→Chef→Puppet
3. **镜像与制品**（11-15）：瘦身→Packer→Registry→SBOM→发布流水线
4. **CI/CD**（16-20）：Jenkins→Gitea Actions→（Woodpecker）→定型
5. **GitOps/策略/安全**（21-25）：Flux→OPA→扫描→密钥→合规门禁
6. **可观测/漂移/灾备**（26-30）：监控→日志→漂移→备份→一体机

## 许可

MIT
