# 23 · IaC 安全扫描三件套：tfsec × trivy × gitleaks

> 10 类编号坏配置，三把扫描器覆盖 10/10——错配交给 tfsec/trivy（同源 AVD 规则），凭证交给 gitleaks（自定义规则），CRITICAL/HIGH 阻断门禁双向验证。

## Background

IaC 的安全缺陷在 apply 之前就能被机器看见：安全组全开、明文口令入库、过期 TLS……人 review 会漏，扫描器不会累。本实验把"安全基线"变成可执行验收：10 类编号坏配置（BAD-1..10，见 bad-configs/main.tf 注释），断言 **≥9 类被扫出**（实测 10/10）、good-configs **零误报**、HIGH+ 阈值门禁**双向**（坏挡下/好放行）。

## What

- `bad-configs/main.tf`：10 类编号坏配置——安全组全开、公网 IP、明文口令默认值、硬编码 AK/SK、S3 公网阻断关闭、EBS 未加密、S3 无加密、过期 TLS、RDS 未加密、IMDSv1
- `good-configs/main.tf`：合规样本（description/加密/IMDSv2 一个不少），断言零发现
- `.gitleaks.toml`：自定义凭证规则 3 条（TF 口令默认值、AKIA 模式、secret_key 赋值）
- `iac_scanning.sh` 六相：scan / coverage（10/10 断言）/ severity（CRITICAL≥2、HIGH≥10）/ good（零发现）/ gate（HIGH+ 双向阻断）/ clean

## When to Use

- IaC 进仓库的 PR 门禁：HIGH+ 阻断、MEDIUM 以下告警
- 凭证防泄漏：Terraform 里的口令默认值、AK/SK 硬编码（扫描器 allowlist 会放行 AWS 文档示例 key——自定义规则才能穿透，见 Pitfalls 1）
- 多工具交叉验证：单工具的评级/规则覆盖不可信，两把刀互补（tfsec 查错配、gitleaks 查凭证）

## Quick Start

```bash
cd labs/23_iac_scanning
./iac_scanning.sh            # 六相全链：scan → coverage 10/10 → severity → good → gate → clean
./iac_scanning.sh coverage   # 单看覆盖率表（每类坏配置标注被哪把扫描器命中）
tfsec bad-configs            # 单发 tfsec
gitleaks detect --no-git -c .gitleaks.toml --source bad-configs   # 单发凭证
```

前置：tfsec v1.28、trivy 0.74、gitleaks 8.30（本机均已装）。

## How It Works

### 覆盖率 10/10 的分工

| 坏配置类 | 扫描器 | 证据 |
|:---|:---|:---|
| BAD-1/2/5/6/7/8/9/10（八类错配） | tfsec | 按资源名断言（如 `aws_security_group.open`、`aws_lb_listener.legacy_tls`） |
| BAD-3/4（明文口令默认值、硬编码 AK/SK） | gitleaks | 按自定义 RuleID 断言 |

tfsec 实测：23 条 failed findings，CRITICAL=2（全开安全组 + 过期 TLS）、HIGH=12——`severity` 相断言 CRITICAL≥2 且 HIGH≥10。

### CRITICAL 阻断门禁

`trivy config --severity HIGH,CRITICAL --exit-code 1` 对 bad-configs 退出 1（挡下）、对 good-configs 退出 0（放行）——接入流水线就是一行（gate 相双向验证）。

## Pitfalls & Q&A

1. **扫描器会放行 AWS 文档示例 key**：trivy secret 对 `AKIAIOSFODNN7EXAMPLE`（最著名的示例 key）零命中——内置 allowlist 故意豁免文档样例。穿透它靠自定义规则（`.gitleaks.toml` 的 `AKIA[0-9A-Z]{16}`），这也是业界的真实做法：通用规则 + 仓库自定义规则叠加。
2. **tfsec 与 trivy 评级不一致**：同一 AVD ID（0107/0047），tfsec 评 CRITICAL、trivy 评 HIGH；发现数也不同（23 vs 21）。门禁阈值跨工具取 `HIGH,CRITICAL`，别假设两家评级一致。
3. **gitleaks 的 `[allowlist]` 是忽略清单**——本实验最初把它当"只扫范围"写反了，导致 0 命中；范围限定用 `--source`，allowlist 只做豁免。
4. **tfsec JSON 形态随版本变**：新版 `results` 直接是数组（旧版 `{failed: []}`），解析要兼容两种形态。
5. **负例的键要整个省略**：S3 加密配置声明了但 `count = 0` 时，tfsec 报的是桶本身的规则（0088/0132）——覆盖成立但机制不同（配置"不存在"vs"存在却关着"是两类发现）。
6. `not container.resources` 式的 undefined 判断在这里同样适用：合规样本要经得起同一把尺子，good-configs 的 description/加密/IMDS 一个不能少（初版被 tfsec 抓出 4 条）。

## 产物清单

- `bad-configs/main.tf`（BAD-1..10 编号注释）/ `good-configs/main.tf`（真零发现）/ `.gitleaks.toml`（3 条自定义规则）
- `iac_scanning.sh`：六相断言（coverage 10/10、severity、good、gate 双向）全绿两遍；报告落 `tmp/reports/`（已清理）
