# 22 · 策略即代码（OPA/Conftest）

> Rego 规则声明安全基线，conftest 在 CI 中作为门禁拦截违规配置。

## 快速开始

```bash
cd labs/22_opa_conftest
./woodpecker_test.sh
```

真实输出：
```
FAIL - bad-deployment - Container 'web' uses :latest tag
3 tests, 1 passed, 0 warnings, 2 failures
== good-deployment: 3 tests, 3 passed, 0 failures
```

## 核心概念

- **Rego**：OPA 的声明式策略语言；`deny` 规则返回非空即违规
- **Conftest**：OPA 的 CLI 包装，接受 JSON/YAML/HCL 输入
- **CI 门禁**：conftest 的非零退出码阻断 pipeline

## 面试要点

- Rego 的 `deny contains msg if` 语法是 OPA v1 的规则声明式写法
- 策略分层：deny（阻断）> warn（告警）> info（提示）
