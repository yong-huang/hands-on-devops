# 20 · 完整 CI/CD：定型流水线与失败阻断

> 实验 18 验证了 Gitea Actions 的 push→绿链路，实验 19 记录了 Woodpecker 的兼容性
> 诊断。本实验回到已验证的 Gitea Actions，定型完整流水线：测试→构建→部署，外加
> **失败注入验证**——好的 CI 不仅跑得绿，还必须"该红就红"。

## 1. 快速开始

```bash
cd labs/20_cicd_full
./cicd_full.sh            # apply（绿）→ fail（注入红灯）→ clean
```

真实输出：

```
=====> [apply] 等待流水线
        [ok] 流水线全绿（runner 日志含 ✅）
=====> [fail] 注入失败用例 → 断言阻断
        [检出] 注入被抓住（runner 日志含 ❌/exit 1）
        [ok] 已 revert
```

## 2. 核心概念

### 2.1 定型流水线的四个阶段

test（语法/断言）→ build（产出物）→ deploy（模拟上线）→ 后续可扩展 SBOM/签名/
门禁。每个阶段失败即阻断全链路——CI 的本质是"门卫"而不是"跑腿的"。

### 2.2 失败注入：测试你的 CI

好 CI 的标志不是"永远绿"而是"该红就红"。注入 `exit 1` 步骤 → runner 日志含 ❌ →
revert 修复 → 回绿。这个闭环在实验 7（Molecule）、18（Gitea Actions）反复出现——
它是 DevOps 的元模式。

## 3. 深入要点

- **门禁 vs 提醒？** 门禁 = 失败即阻断合并/部署（branch protection + required
  checks）；提醒 = 通知但不阻塞。企业 CI 至少要有一道硬门禁。
- **发布留痕？** 每次 pipeline 关联 commit SHA、构建产物、部署环境与时间戳——
  实验 идти15 的追溯清单在 CI 中的等价物。

## 4. 总结

CI 定型完毕。阶段五（21-25）与六（26-30）覆盖 GitOps、策略、安全、可观测、
漂移与灾备——每一项都建立在此处验证的 push→pipeline 基础上。
