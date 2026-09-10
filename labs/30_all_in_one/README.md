# 30 · 终极串联——DevOps 一体机

> 汇总 01-29 全部实验的一键演示入口。

```bash
# 按顺序执行各实验主脚本，跑通完整 DevOps 生命周期：
# 靶场 → IaC → 配置管理 → 镜像 → CI → GitOps → 策略 → 安全 → 监控
cd labs/05 && make lab-up
cd labs/06 && ./ansible_role_vault.sh
...
```

## 企业栈对照

| 层 | 本机栈 | 企业栈 |
|:---|:---|:---|
| 基础设施 | kind/k3s | EKS/GKE/AKS |
| IaC | Terraform + 本地 state | Terraform Cloud / Atlantis |
| CI | Gitea Actions | Jenkins / GitHub Actions |
| CD | Flux | ArgoCD / Flux Cloud |
| 策略 | Conftest | OPA Gatekeeper / Kyverno |
| 密钥 | SOPS+age | Vault / AWS Secrets Manager |
| 监控 | Prometheus + Grafana | Datadog / New Relic |
| 日志 | Loki | ELK / Splunk |
| 制品 | registry:2 | Harbor / ECR |
