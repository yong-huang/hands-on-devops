# 21 · 流水线安全加固：半导体 IP 防泄漏

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 21 · 阶段六「生产化」
> 变量 masked/protected 化 + 外部贡献者 MR 的 secret 隔离实证 + artifact/LFS 公开性审计
> 验收在 `security.sh verify`：dev1 读 protected 变量 403 / 四项目非 public / 匿名 LFS 401，全过打 `[ok]`

## Background

半导体内网不是"天然的保险箱"——流水线里的 PAT、LFS 里的 PDK、artifact 里的 bitstream，每一层配错可见性都是 IP 泄漏口。本实验把安全做成**可验证的断言**而不是口头约定：外部身份读不到机密、仓库不公开、匿名连 LFS 握手都被拒。

## What

心智模型一句话：**GitLab 的可见性是三把锁——变量锁（masked+protected）、仓库锁（private）、对象锁（LFS 鉴权），逐把实测**。

| 锁 | 机制 | 实测证据 |
|:---|:---|:---|
| 变量锁 | GITLAB_PAT masked+protected：仅 protected ref（main/tag）可见 | dev1 的 PAT 读变量接口 → 403 |
| 仓库锁 | 四项目全部 private | 可见性审计逐项目断言 |
| 对象锁 | LFS batch API 匿名请求 → 401 | 无凭据 curl 实测 |

验证方法：`./security.sh verify` 三条断言；`./security.sh status` 看变量清单。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 平台改造后的安全回归 | verify 三条断言（变量/仓库/对象锁逐把测） |
| 外部贡献者/外包参与 | protected 变量天然对非 protected ref 隔离（fork MR 不可达） |
| 防"顺手 public" | 审计循环扫全部项目可见性，public 即红 |
| 新增敏感变量 | 照 GITLAB_PAT 的 masked+protected 样板 |

## Quick Start

前置：项目 4/8 完成（dev1 用户与规范克隆在位）、`../04_mr_gate/.dev1-token` 有效。

```bash
./security.sh up       # 变量收紧 + 门禁规则核查（幂等）
./security.sh verify   # 三条安全断言
./security.sh status   # 变量清单（值不显示）
```

`verify` 的真实输出（实测，全过）：

```
=====> [verify1] 模拟外部贡献者 MR：protected 变量不可达
  [ok]   dev1 读 protected 变量被拒（HTTP 403）——fork MR 天然拿不到
=====> [verify2] artifact 公开性审计：无 IP 文件暴露在公开通道
  [ok]   四个项目均无公开暴露
=====> [verify3] LFS 大文件不可匿名拉取（IP 实体保护）
  [ok]   匿名 LFS batch 请求被拒（HTTP 401）

[ok] 项目 21 全部验收断言通过
```

## How It Works

### protected 变量的隔离是 ref 级而非用户级

GITLAB_PAT 的 protected=true 表示"只有 protected refs（main、v* tag）的流水线能读到"。dev1 从 feature 分支开的 MR 流水线天然拿不到——不需要逐用户配置。

副作用：tag 流水线也读不到，除非 tag 匹配 protected wildcard（P19 踩过，改 protected=false 或配 `v*`）。

### 审计 = 用 API 把安全属性变成数据

四项目可见性、变量 masked/protected、LFS batch 匿名响应码——全从 API/HTTP 拉取并断言。安全属性一旦可断言，就能进 CI 定期跑（安全回归），而不是靠 quarterly review 的人眼。

## Pitfalls & Q&A

**Q：为什么 license 门禁 job 不需要额外规则？** 它在 with_license 包装内依赖 license-mock（内网服务）与 P14 的门禁；fork MR 即使跑了仿真 job，也碰不到 protected 变量与内网 License 池——隔离由变量锁与网络位置共同完成。

**Q：masked 有什么限制？** 值需 ≥8 字符、单行、Base64 类字符集——PAT 天然满足。masked 只防日志泄漏，不影响功能。

**Q：审计里 runner-lab/push-lab 也查吗？** 查——安全审计不豁免"只是靶场"的项目：靶场数据常含真实凭据副本，恰恰是最容易漏锁的房间。
