# 23 · IaC 安全扫描

> tfsec/trivy 扫描 Terraform 配置中的安全漏洞——"安全基线"不再靠人记忆。

## 快速开始

```bash
cd labs/23_iac_scanning
./iac_scanning.sh
```

## 核心概念

- **tfsec**：Terraform 专用静态扫描（Rules 表即安全基线）
- **trivy config**：通用 IaC 扫描（支持 TF/K8s/Dockerfile）
- 坏配置样例含 10 种常见漏洞：开放 SG、公网 IP、明文密码、公开 S3 等

## 面试要点

- 静态扫描 vs 动态审计：tfsec 扫代码（shift-left），CloudTrail 审计行为
- CI 门禁：CRITICAL 阻断，HIGH 告警
