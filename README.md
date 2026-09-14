# hands-on-devops

一条完整 DevOps 流水线的搭建与演练：**IaC → 配置管理 → 镜像/制品 → CI/CD → GitOps/策略 → 可观测/漂移**
覆盖 Terraform · Ansible · Molecule · Salt · Chef · Puppet · Packer · Woodpecker · Gitea Actions ·
Prometheus/Loki/Grafana · SOPS/Vault · cosign/syft 等工具链。
**零云依赖**：Docker 容器当被管节点（"靶场环境"），macOS 本机全部可跑、全部免费。

> 配套清单：`docs/devops.md`（30 项目 · 6 阶段 · 每项目带验收标准与 AI 提示词）

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

## 目录结构

```
hands-on-devops/
├── README.md                        # 本文件
├── docs/
│   └── devops.md                    # 原始 30 项目清单
├── Makefile                         # 统一入口（lab-up / lab-down / demo）
├── scripts/
│   ├── load_resources.sh            # 镜像预载（含 daocloud 回源）
│   ├── tfrc.sh                      # Terraform provider 离线镜像
│   ├── docker-env.sh                # Docker socket 自动探测
│   └── tf-mirror/                   # kreuzwerker/docker provider 离线包
└── labs/
    └── NN_short_name/
        ├── README.md                # 8 节教程（为什么→图→快速开始→概念→字段→结构→深入→总结）
        ├── xxx.sh                   # 主演示脚本（apply/observe/.../clean 全真机验证）
        ├── configs/ 或 manifest     # 声明式配置（注释密度远高于生产）
        └── images/
            ├── xxx.sequence.json    # 图源（typed JSON IR，可用配套工具重新渲染）
            ├── xxx.html             # 交互版（自包含单文件）
            └── xxx.svg              # 双主题矢量图（README 内嵌）
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
- **Docker socket**：`scripts/docker-env.sh` 自动探测 Desktop/OrbStack 并导出
  `DOCKER_HOST`（Go/SDK 客户端不认 docker context）
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
