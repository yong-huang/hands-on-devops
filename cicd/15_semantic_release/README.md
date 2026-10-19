# 15 · semantic-release 版本工程——提交信息驱动发布

> 版本号不靠人拍脑袋：conventional commits（`fix:` / `feat:` / BREAKING
> CHANGE footer）→ semantic-release 自动定 semver 递升、生成 changelog、
> 打 tag、发 GitHub Release。发布从"仪式"变成"推代码的副产品"。
>
> 本实验双线验证：本地 dry-run 断言三组递升（fix→1.0.1 / feat→1.1.0 /
> 破坏→2.0.0），真仓库 cicd-lab 四连发并 gh api 断言 Release 内容。

## Background

手写版本号的问题不是累，是**不可信**：改了破坏性接口却只升 minor、
changelog 三个月没更新、tag 和实际内容对不上——发布历史失去审计价值。

semantic-release 把版本号变成提交信息的纯函数：`fix:` → patch、`feat:`
→ minor、破坏性变更 → major，changelog 直接由提交列表生成。人只负责写
规范的提交信息，版本工程全自动。

## What

**定义**：semantic-release = `提交分析 → semver 递升 → changelog 生成 →
tag + Release 发布` 的发布流水线；conventional commits 是它的输入协议。

| 提交形态 | 递升 | 本地 dry-run 实测 | 真仓库发布 |
|:---|:---|:---|:---|
| `fix: handle empty token` | patch | 1.0.1 | v1.0.1 |
| `feat: add export endpoint` | minor | 1.1.0 | v1.1.0 |
| `BREAKING CHANGE:` footer | major | 2.0.0 | v2.0.0 |
| `chore: docs only` | 不发版 | no relevant changes | ——（未推） |

版本工程像自动售货机：投币规格（提交格式）对了才出货（发版）——`fix:`
出小杯（patch）、`feat:` 出中杯（minor）、BREAKING CHANGE 出大杯（major），
投错币种（chore）机器直接退币（no relevant changes）。

失效边界：类比没覆盖"首单特权"——仓库没有任何 tag 时，第一笔发布固定
1.0.0，与提交类型无关（真仓库实测：`feat:` 首发得到 v1.0.0 而非累加）。

![semantic-release 版本工程](images/semrel.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/15_semantic_release/images/semrel.html)（或本地打开 [`images/semrel.html`](images/semrel.html)）。

看图方法：上行为发布主链（提交 → 定版本 → 生成 changelog → Release），
下行为两种触发形态——真仓库的 push workflow 与本地的 dry-run 演练，它们
复用同一套 analyzer/notes，只差"发不发"。

## When to Use

- 面向外部用户的库/服务：版本与 changelog 是契约，必须可审计；
- 多人协作仓库：发布规则写进工具而不是写在 wiki 里靠自觉；
- 反例：纯内部工具（没人消费版本号）、提交信息不可控的仓库——garbage
  in, garbage out，semantic-release 的前提是提交纪律。

## Quick Start

前置：node/npm、gh（已认证）+ 你有推送权限的真仓库（脚本顶部
`OWNER`/`REPO` 可改成自己的 fork）。semantic-release 不入库，自行装：
`npm install --prefix .tools semantic-release@24`（`.tools/` 已忽略）。

```bash
cd cicd/15_semantic_release
./semantic_release.sh local        # 本地 dry-run：三组递升 + chore 不发版
./semantic_release.sh real-setup   # 克隆真仓库，装 workflow + 配置并推送
./semantic_release.sh real-release # 四连发：1.0.0 → 1.0.1 → 1.1.0 → 2.0.0
./semantic_release.sh real-verify  # gh api 断言 Release 与 changelog
./semantic_release.sh clean        # 清 .tmp（真仓库 Release 保留为证据）
```

`local` 段的真机取证（完整输出见脚本运行日志）：

```
        [ok] fix: → patch 1.0.1
        [ok] feat: → minor 1.1.0
        [ok] feat!: → major 2.0.0
        [ok] chore: → 不发版（no relevant changes）
```

`real-release` / `real-verify` 段（真仓库 cicd-lab）：

```
        [ok] feat → v1.0.0（GitHub Release 已出现）
        [ok] fix → v1.0.1（GitHub Release 已出现）
        [ok] v2.0.0：body 非空且含 'change auth header format'
        [ok] 仓库现有 4 个 Release——版本工程链路（commit→tag→release）全通
```

诚实预期：dry-run 输出的 "Published release" 字样是**模拟发布**，本地不
产生 tag/Release；真仓库的 v1.0.0 由 `feat:` 首发产生（首单固定 1.0.0），
与本地从 v1.0.0 tag 起步的递升断言是两条互补的证据线。

## How It Works

### 递升规则与提交协议

commit-analyzer 逐条解析提交：type 决定 patch/minor，`BREAKING CHANGE:`
footer 触发 major，`chore:`/`docs:` 默认不发版。changelog 由
release-notes-generator 按类型分组——提交信息就是 API，格式即语义。

### 双线验证：dry-run 与真仓库各管一半

本地 dry-run 复用同一套 analyzer/notes，只断言递升不发版。真仓库由
`push→main` 触发 workflow，GITHUB_TOKEN 带 contents:write 经 API 发布；
脚本逐笔推送并轮询 Release 出现，保证发布顺序性。

### workflow 的三个必要条件

`fetch-depth: 0`——全量历史与 tag 是分析基础；`contents: write`——
GITHUB_TOKEN 要能打 tag 发 Release；固定 `@24` 大版本防规则漂移。三者
缺一，发布链断。

## Pitfalls & Q&A

- **① semantic-release@24 的 analyzer 不认 `feat!:` 简写**：整个头部
  解析失败，被判"不触发发布"。major 必须用 footer——提交体另起一行
  `BREAKING CHANGE: 说明`（semver 语义等价）。
- **② dry-run 也要求 `repositoryUrl` 是合法 URL**：notes 生成器要对它
  `new URL()`，校验还会 `git ls-remote`——本地仓库用 `file://` + 绝对路径
  即可离线通过。
- **③ 插件从当前目录解析**：`@semantic-release/*` 虽是 semantic-release
  的自带依赖，但 config 里的插件引用按 cwd 解析——玩具仓库要
  `ln -s` 安装目录的 `node_modules`，否则 MODULE_NOT_FOUND。

Q&A：

- **changelog 里提交前缀去哪了？** release-notes-generator 按类型分组
  （Features/Fixes/Bug Fixes…）并剥掉 `feat:` 等前缀——所以 gh api 断言
  要匹配去前缀的主题，而不是原始提交行。
- **首个发布为什么不受提交类型影响？** 没有任何 tag 时不存在"递升"的
  基数，semantic-release 固定发 1.0.0。要首发就是 0.x，用 `release:
  {branches}` 配置或预置 v0.x tag。
- **推送 workflow 那一笔会触发发布吗？** 会触发运行，但那笔提交是
  `ci:` 类型——analyzer 判定无相关变更，运行绿着结束、不发版。发布
  顺序性由脚本"等上一笔的 Release 出现再推下一笔"保证。
