# 28 · 配置漂移检测与治理

> TF plan 检测基础设施漂移 → 分析根因 → git push 修复 → TF apply 回正。

## 核心概念
- `terraform plan -detailed-exitcode`: exit 0=无漂移, 2=有漂移
- 漂移来源：手动 kubectl、控制台修改、其他工具变更
- 治理 SOP：检测 → 定位根因 → git push 修复 → apply 回正 → 复盘
