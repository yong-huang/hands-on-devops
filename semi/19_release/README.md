# 19 · 发布工程：vTag 到客户交付包

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 19 · 阶段五「构建、制品与发布」
> 推 vTag → 全链重构建 → changelog（MR 列表）→ 客户交付包（RTL+bitstream+MANIFEST+审计单）→ GitLab Release
> 验收在 `release.sh verify`：tag 流水线全绿 / Release+changelog / 交付包 sha256+审计单，全过打 `[ok]`

## Background

前两个实验把 bitstream 变成了"有编号、有签名"的制品；发布工程是最后一公里：**把制品、变更记录、审计单打包成客户拿到手的交付物**，并用 GitLab Release 把"这个版本有什么"钉在 tag 上。

半导体交付的特殊性：交付包不只是二进制——RTL 源码、审计单（谁在何时构建的、内容清单）都是交付内容。

## What

心智模型一句话：**vTag 是扳机，Release 是货架，交付包是货架上的箱子**。

| 步骤 | 实现 |
|:---|:---|
| 触发 | `rules: if $CI_COMMIT_TAG =~ /^v/` + `needs: [fpga]`（发布=全链重构建） |
| changelog | API 拉 merged MR 列表 → Markdown 列表 |
| 交付包 | tar.gz：rtl/ + syn/top.bin + MANIFEST.sha256 + CHANGELOG + audit.json |
| Release | Releases API 创建，assets 挂 Generic Packages 的交付包链接 |

验证方法：`./release.sh verify`——推一个 vTag，等全链跑完，逐项断言。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 客户交付 | 交付包 tar.gz + Release 页（本实验）——审计单是半导体的合规刚需 |
| 内部快速分发 | 只用 Generic Packages（P18），Release 属对外动作 |
| 紧急补丁 | 同一流程：hotfix 分支 → MR → main → 新 vTag |
| 防呆 | needs fpga：bitstream 没构建出来就发不了版 |

## Quick Start

前置：项目 17/18 完成。

```bash
./release.sh up       # 推 release stage + make_release.py
./release.sh verify   # 推 vTag → 全链 → 三项断言（约 10 分钟）
./release.sh clean    # 删演示 Release/tag
```

`verify` 的真实输出（实测，全过）：

```
=====> [release] 推 vTag 触发发布流水线
=====> [wait] 等 release 流水线（tag 触发，最长 15 分钟）
  [ok]   发布流水线全绿（tag 触发全链重跑）
=====> [verify] 验收① Release 自动创建 + changelog 含 MR 标题 + 审计单字段
  [ok]   Release 描述含 changelog（MR 列表）
=====> [verify] 验收② 交付包解包校验（sha256 全对 + 审计单字段）
  [ok]   交付包 sha256 全对 + audit.json 四字段齐全

[ok] 项目 19 全部验收断言通过
```

## How It Works

### tag 流水线的 needs 语义

`release` job `needs: [fpga]`，而 fpga 的 rules 必须同时放行 tag（`$CI_COMMIT_TAG =~ /^v/`）——否则 tag 流水线里 fpga 不存在，needs 悬空导致**整条流水线 0 jobs 直接 failed**（实测踩过）。

加了 tag 规则后，tag 流水线=全链重构建：bitstream 从 tag 指向的代码现场新构建，不是复用 main 的旧产物——发布语义的正确姿势。

### MANIFEST：包内自校验

交付包内置 MANIFEST.sha256（对 top.bin/CHANGELOG/audit.json 逐文件指纹）。消费端解包后逐条对账——不依赖外部数据库就能发现传输损坏。P18 的 cosign 签名保护的是"包外"（Generic Packages 的对象），MANIFEST 保护的是"包内"。

### CI 容器内的 URL 与工具

CI job 容器里 localhost 不是 GitLab（runner 的 network_mode 使 job 容器与 gitlab 同网络，别名 `gitlab`）——make_release.py 按 `CI_JOB_ID` 是否存在切换 URL。

另外 eda-base 镜像无 curl：uploads 用手工 multipart（urllib 构造 boundary）、Generic Packages 用 PUT——两处都别引外部依赖。

## Pitfalls & Q&A

**坑 1：needs 悬空 = 流水线 0 jobs failed。** needs 引用的 job 不在本流水线（rules 没放行 tag）时，GitLab 直接判整条流水线 failed 且 jobs 为空——不是"跳过 release"而是"全没跑"。

yaml_errors 为 None，排障只能从 rules 语义入手。

**坑 2：protected 变量不对 tag 生效。** GITLAB_PAT 设了 protected=true，tag 不是 protected ref → release job 读不到 → KeyError GITLAB_PAT。

修法：变量关掉 protected，或给 tag 配 protected wildcard `v*`。

**坑 3：/uploads 与 /packages 的接口形态不同。** 前者收 multipart 文件体（JSON 报 file is missing），后者收裸 body PUT。eda-base 无 curl——都用 urllib 手工构造（multipart 的 boundary 手拼）。

**Q：为什么每次 verify 都产生新版本号？** 版本带时间戳（v0.2.<epoch>）——发布不可变，重复验证不能覆盖旧 tag。clean 会把演示 Release/tag 一起删。
