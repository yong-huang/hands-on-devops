# 25 · 集成点③：合规流水线

> 三道合规门串行验证：策略门（OPA）→ 安全门（trivy/tfsec）→ 密钥门（明文扫描）。

## 快速开始

```bash
cd labs/25_compliance_pipeline
./compliance_pipeline.sh
```

## 门禁链

| 门 | 工具 | 阻断条件 |
|:---|:---|:---|
| 策略门 | conftest | deny 规则非空 |
| 安全门 | trivy/tfsec | CRITICAL 存在 |
| 密钥门 | grep/扫描 | 明文密码存在 |

## 面试要点

- 合规流水线的本质：**把安全基线从"文档"变成"代码"**——门禁不可绕过
- shift-left：越早拦截（IDE → pre-commit → CI → CD → 运行时），修复成本越低
