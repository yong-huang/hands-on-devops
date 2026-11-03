# 漂移治理 SOP（检测 → 定位 → 修复 → 复盘）

## 1. 检测（双探针 + 专项，各管一类漂移）

| 探针 | 命令 | 检出漂移类 | 原理 |
|:---|:---|:---|:---|
| TF plan | `terraform plan -detailed-exitcode`（0=无漂移 2=有漂移） | 容器被手动重建/删除/改端口等基础设施漂移 | refresh 读实际容器状态对比期望态 |
| Ansible --check | `ansible-playbook --check`（0 changed=无漂移） | 容器内配置被人手改 | 幂等任务逐项对比期望与实际 |
| 镜像 digest 对比 | registry API `Docker-Content-Digest` vs 基线记录 | tag 被覆盖（供应链劫持） | TF/ansible 都**看不到** tag 背后的内容变化 |

## 2. 定位根因（分类决策树）

- TF plan 红 + ansible 绿 → 基础设施层漂移（谁动了容器？`docker events`、控制台操作记录）
- ansible 红 + TF 绿 → 配置层漂移（容器内文件被人手改）
- digest 探针红（其余绿）→ **registry 层漂移**：同 tag 被覆盖——TF plan **检测不到**（它只看容器引用的 tag 字符串），必须专项探针；这也是"tag 引用不可审计，生产应 pin digest"的实证

## 3. 修复（按根因一键回正）

| 漂移类 | 回正动作 |
|:---|:---|
| 配置漂移 | `ansible-playbook`（正常模式，幂等重渲染） |
| 基础设施漂移 | `terraform apply`（TF 按期望态重建） |
| tag 覆盖 | 重新 push 干净镜像恢复 tag → `terraform apply -replace` 重建容器 → 刷新 digest 基线 |

## 4. 复盘

- 漂移被检出 ≠ 结束：记录**谁、何时、为什么**（本实验用 docker events 人为模拟）
- 长期治理：收编变更入口（GitOps，labs/21）——让"手动改集群"在流程上不可能
- 基线更新：合法变更后**必须刷新期望态与 digest 基线**（否则下次检测全是假阳性）
