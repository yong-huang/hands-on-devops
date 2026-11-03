# 30 · 🏁 终极串联——DevOps 一体机

> 六环节故事线：底座 → 合规 push（三道门）→ 部署 v2 → 监控/日志双可见 → 漂移注入被检出回正 → 全栈销毁零残留。一键编排、全程无手工干预，两遍全绿。

## Background

01-29 的每个实验是独立乐器，30 是**合奏**：底座（26/27 监控日志 + 28 期望态 + 24 密钥 + 25 CI 基建）拉起后，故事线走完一个完整 DevOps 生命周期——`push 合规代码 → 三道门 Success → 部署 v2 → 指标/日志双可见 → 注入漂移被检出回正 → 全栈销毁`。它同时是 **01-29 的回归测试**：任何一环坏了故事线就断。

## What

- `all_in_one.sh`：六环节（up / pipeline / deploy / observe / drift / destroy），每环节复用对应实验的脚本（`run_lab <dir> <script>` 模式，零复制）
- 复用资产：25 的三道门 CI（含工具镜像）、26/27 的监控日志栈、28 的 TF 期望态与漂移探针、24 的 age 密钥

## When to Use

- 新机器验证环境就绪：一条命令跑完整链
- 大改动后的回归：故事线断在哪，哪个实验的资产退化了
- 给团队演示完整 DevOps 生命周期（六环节约 6 分钟）

## Quick Start

```bash
cd labs/30_all_in_one
./all_in_one.sh demo    # 六环节全链（两遍全绿）
./all_in_one.sh up      # 只拉底座（监控/日志/CI/靶场）
./all_in_one.sh destroy # 全栈销毁
```

前置：21-25、28 各实验已实现（脚本会探测并复用其资产）；docker 正常。

## How It Works

### 故事线的因果链

```
S1 底座: 监控(291xx) + 日志(292xx) + 靶场(28230, TF期望态) + age密钥 + CI(3356, 三道门镜像)
S2 push 合规代码 → Gitea Actions 三道门 → run Success        (25)
S3 deploy v2 → 靶场容器页面更新 + ci_deploys_total 推入       (28 容器 + 26 pushgateway)
S4 Prometheus 查到发布指标 + Loki 查到日志流                  (26/27 双可观测实证)
S5 手改配置 → ansible --check 检出 → 回正 → 终态四断言        (28)
S6 全栈销毁（卷级清理，零残留）
```

### 跨实验资产衔接的三个实测要点

1. **tmp 路径不能撞名**：28 与 27 的运行时都在各自 `tmp/`（27 的日志目录被 28 的 setup `rm -rf tmp` 清掉会断日志流——各实验 tmp 相互独立是隐含契约）
2. **TF mirror 必须绝对路径**：28 被 30 调用时 TF 在 `tf/` 子目录解析，相对 mirror 路径 `lstat` 失败（实测）
3. **端口表是资产**：26 的 291xx、27 的 292xx、28 的 28230、25 的 3356——错峰分配让六个栈同时在线不冲突（根 README 端口分配表的价值实证）

## Pitfalls & Q&A

1. **compose 服务 `--wait` 的就绪语义**：`docker compose up -d --wait` 等容器 healthy，但 Prometheus 的 `/-/ready` 在 OrbStack 端口冲突时会 404（打到别的进程）——探活路径与端口错峰都要对。
2. **pushgateway 指标有抓取延迟**：推送后等 Prometheus 下一轮抓取（5s 周期）再断言。
3. **Loki summary 值是字符串**：`r['value'][1]` 是 str，sum 前要 `int()`。
4. **跨实验调用的相对路径**：`run_lab` 先 `cd` 再执行，但被调脚本内部的相对引用（如 TF mirror、provider 二进制源）必须绝对路径化。

## Pitfalls 补充：企业栈对照（本机栈 → 企业栈）

| 层 | 本机栈 | 企业栈 |
|:---|:---|:---|
| 基础设施 | kind / OrbStack 容器 | EKS / GKE / AKS |
| IaC | Terraform + filesystem mirror + local state | Terraform Cloud / Atlantis + S3+DynamoDB 后端 |
| 配置管理 | Ansible（docker 连接） | Ansible Tower / Salt / Puppet |
| 镜像构建 | Packer + docker build | Packer + EC2 Image Builder |
| CI | Gitea Actions + act_runner | Jenkins / GitHub Actions / GitLab CI |
| 制品 | registry:2 | Harbor / ECR / Artifactory |
| CD | Flux（21） | ArgoCD / Flux Cloud |
| 策略 | Conftest（22） | OPA Gatekeeper / Kyverno |
| 安全扫描 | tfsec/trivy/gitleaks（23） | Trivy Cloud / Snyk / GitHub Advanced Security |
| 密钥 | SOPS + age（24） | Vault / AWS Secrets Manager / External Secrets |
| 监控 | Prometheus + Grafana + pushgateway（26） | Datadog / New Relic / Mimir |
| 日志 | Loki + Promtail（27） | ELK / Splunk / Grafana Loki Cloud |
| 漂移治理 | TF plan + ansible --check + digest 探针（28） | driftctl / env0 / Spacelift drift detection |
| 备份 | tar 卷 + state 副本（29） | Velero / K8s snapshot + 对象存储版本化 |

## 产物清单

- `all_in_one.sh`：六环节故事线（demo 全链两遍全绿；各相可单独执行）
- `apps/`：v1/v2 页面载荷（S3 部署断言用）
- 验收对照：devops.md 项目 30 的"六环节无手工干预"由本脚本 demo 相机械化达成
