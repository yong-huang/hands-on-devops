# 24 · 密钥治理（SOPS + age）

> 密钥以加密形式入 git，部署时解密——"配置和密钥分离"的实践。

## 快速开始

```bash
cd labs/24_sops_age
./sops_age.sh
```

真实输出：
```
=====> [encrypt] 密文无明文
=====> [decrypt] 解密成功值一致
```

## 核心概念

- **age**：现代加密工具（替代 GPG），密钥对极简
- **SOPS**：Mozilla 出品，按字段加密 YAML/JSON（不是全文加密）
- **gitignore 密钥文件**：tmp/key.txt 不入库；加密后的 secrets.yaml 可安全入库

## 深入要点

- SOPS vs Sealed Secrets vs External Secrets：SOPS 是文件级加密；后者是集群内解密
- 密钥轮换：重新加密（sops --rotate）→ git diff 只看到新密文
