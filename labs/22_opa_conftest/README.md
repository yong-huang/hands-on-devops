# 22 · 策略即代码（OPA/Conftest）：Rego 基线 + CI 门禁

> 安全基线写成 Rego（可 review、可 diff、**可测试**），conftest 作为 CI 门禁：违规配置一票否决，warn 层告警不阻断。

## Background

配置审查靠人眼看 PR，规则就不一致、不可追溯。策略即代码把"什么叫合规"写成**代码**：Rego 规则进仓库、随 PR 评审、有单元测试、在 CI 里非黑即白地执行。OPA 是策略引擎，Conftest 是它的 CLI 门禁形态——输入可以是 YAML/JSON/HCL 等任意结构化配置。

## What

- `policies/`：4 条 deny（:latest、缺资源限制、特权容器、缺 app/team label）+ 1 条 warn（非 root）+ **策略单测**（`deny_latest_test.rego`，5 个 `test_` 规则）
- `fixtures/`：6 份输入——1 合规 + 4 类违规 + 1 多文档 YAML（好/坏各一）
- `conftest_policy.sh` 八相：policies / verify（策略单测）/ pass / deny（逐类断言消息与退出码）/ yaml（多文档一票否决）/ warn（不阻断分层）/ gate（CI 门禁模拟）/ clean

## When to Use

- K8s 清单进集群前的基线门禁（镜像 tag、资源限制、特权、归属 label）
- 任何结构化配置的策略审查：Terraform plan（JSON）、Dockerfile、PR 元数据——conftest 都吃
- 分层治理：deny 挡红线（安全），warn 提建议（最佳实践），不把告警当阻断用

## Quick Start

```bash
cd labs/22_opa_conftest
./conftest_policy.sh          # 八相 16 断言，两遍全绿
conftest test fixtures/bad-deployment.json -p policies/   # 单发
conftest verify -p policies/                              # 只跑策略单测
```

前置：conftest + OPA（本机已装；`brew install conftest` 亦可）。

## How It Works

### 输入契约是第一坑

策略读的是 `input.resource.kind` / `input.resource.spec...`——**fixture 的层级结构必须与策略假设一致**。本实验的隐藏考点：把 `kind` 写在文档顶层（K8s 原生清单的样子）而策略期望它在 `resource` 之下时，所有规则**静默空转**，违规配置 12 项全过、退出码 0。排查手法：`conftest parse <file>` 看 conftest 眼里的输入长什么样。策略上线的正确姿势：先定输入契约，再写规则，再用单测锁住契约（`deny_latest_test.rego` 里的 `*_input` 常量就是可执行契约）。

### 规则分层与退出码

- `deny contains msg if {...}`：每条命中的 deny 汇总成 FAIL 行，任一命中 → 退出码 1
- `warn contains msg if {...}`：WARN 行输出，**不影响退出码**——告警层别拿来挡发布
- 多文档 YAML 逐文档求值：12 项 = 6 规则 × 2 文档，只拦违规的那个文档，但整体 rc=1（门禁语义一票否决）

### 策略测试（verify）

`conftest verify -p policies/` 等价 `opa test`：跑 `*_test.rego` 里的 `test_` 规则。模式：

```rego
test_latest_tag_denied if {
    msgs := [m | some m in deny with input as latest_input]
    some m in msgs
    contains(m, "uses :latest tag")
}
```

5 个单测锁住：合规输入零 deny、各类违规确实被各自规则命中（而不是"碰巧有 deny 输出"）。Rego 细节：`not some m in msgs` 是非法语法（v1 禁止否定 some），负向断言用推导式计数 `count([...]) == 0`。

## Pitfalls & Q&A

1. **fixture 键必须"整个省略"而非置空**：`not container.resources` 对 `resources: {}`（空 dict）不触发——负例要真的没有这个键。空对象是"定义了但为空"，`not` 只对 undefined 生效。
2. **`conftest --version` 显示 "dev"**：本机装的构建版，行为正常；想知道配套 OPA 版本用 `opa version`。
3. **规则数就是测试数**：每个输入文档 × 每条 deny/warn 规则 = 1 项 test。6 规则 × 2 文档 = 12 项——断言摘要时按这个算，别拍脑袋。
4. **`not some ... in ...` 非法**（OPA v1）：负向存在性判断用推导式 + `count == 0`。
5. CI 里最小门禁就是一行：`conftest test manifests/ -p policies/`——非零退出码天然阻断 pipeline（gate 相演示了双向：违规挡下、合规放行）。

## 产物清单

- `policies/`：deny_latest（2 deny + 1 warn）/ deny_privileged / require_labels（2 deny）/ deny_latest_test（5 单测）
- `fixtures/`：good / bad（latest+无限制）/ bad-privileged / missing-labels / warn-only / batch.yaml（多文档）
- `conftest_policy.sh`：八相 16 断言全绿（两遍）；`.logs/` 留档
