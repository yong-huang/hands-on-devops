# 21 · Flux GitOps：声明式部署与调谐

> Flux 将集群状态声明为代码：你写 YAML → Flux 控制器持续调谐实际状态→ 两者永不漂移。

## 快速开始

```bash
cd labs/21_flux_gitops
./flux_gitops.sh apply     # 安装 Flux + 部署 demo
./flux_gitops.sh drift     # 注入漂移（教学：无纳管时漂移不被修正）
./flux_gitops.sh clean     # 卸载
```

## 核心概念

- **Flux 控制器**：source-controller（拉取源）+ kustomize-controller（调谐目标）
- **GitOps 调谐**：实际状态 ← 声明状态，不可逆向修改
- **漂移**：手动 kubectl scale 修改副本数后，若资源纳管于 Kustomization，Flux 自动回正

## 面试要点

- GitOps 与 CI/CD 的区别：GitOps 是**持续调谐**（reconciliation），不是一次性部署
- Pull vs Push：Flux 是 pull 模型（集群内 controller 主动拉取），更安全
- Flux vs ArgoCD：Flux 更轻量/原生 kustomize；ArgoCD UI 更强
