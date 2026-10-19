# 13 · monorepo 增量构建——affected 检测与 job 级 skip

> monorepo（多个模块/服务放在同一个仓库里）最常见的浪费：改一行 A 模块，
> 流水线把 B、C 的构建原样再跑一遍。
> affected 检测 = `git diff` 上次成功构建的 commit → 变更文件映射到模块 →
> 沿依赖图反向闭包；job 级 `if` 让未命中的构建 job 由 runner 标记
> **skipped**——在入口就不排队，而不是跑完再判断。
>
> 本实验用 act 本地跑三模块玩具 monorepo：只改 A → B/C 被 skip；
> 改共享库 → 三模块全构建；无变更重推 → 全 skip（幂等：重复执行结果
> 不变，不产生任何副作用）。

## Background

02 的矩阵是"全都跑"——组合再多也是全量。monorepo 的正确姿势是"只跑受
影响的"，它依赖两个前提：

**可信的比对基准**（上次成功构建是哪个 commit？）和**正确的依赖图闭包**
（改共享库要不要连带构建依赖它的模块？）。前者错了会漏构建，后者错了会
错构建——两个都靠不住时，团队只好退回全量，monorepo 体验崩塌。

## What

**定义**：affected 检测 = `变更文件 → 模块 → 反向依赖闭包` 的纯函数；
job 级 skip = `if` 条件为假的 job 不进入执行队列。

| 机制 | 本实验的实现 | 实测断言 |
|:---|:---|:---|
| affected 检测 | `detect.sh`：diff + 反向闭包 | `["a"]` / `["a","b","c"]` / `[]` |
| job 级 skip | `if: contains(fromJSON(...), 'a')` | 零日志 + 产物字节未动 |
| 基准指针 | `.last-built` 只在成功后回写 | 机制保证：失败不污染基准 |

affected 检测像医院分诊：挂号单（diff）看挂了哪个科（模块），但会诊规则
（依赖图）决定要不要连带检查别的科——改共享库等于"检验科停机"，全院
会诊（三模块全构建）。

失效边界：分诊不知道"两个科室共用一台仪器"这种隐式依赖——依赖图必须
人工维护，**漏一条边就漏一次构建，且不报错**（最危险的静默失效，见
Pitfalls ③）。

![monorepo 增量构建](images/monorepo.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/13_monorepo/images/monorepo.html)（或本地打开 [`images/monorepo.html`](images/monorepo.html)）。

看图方法：左→右是主链（变更 → 检测 → if 门 → 命中构建），if 门向下分出
skipped 分支；下方 `.last-built` 是检测的比对基准，成功后回写、失败不动。

## When to Use

- 模块数 ≥ 3 且边界清晰的 monorepo：构建越慢，skip 省得越多；
- 共享库变更需要扇出时：靠依赖图而不是"改了什么都要重跑"的肌肉记忆；
- 反例：模块间边界模糊、隐式共享状态多——依赖图维护成本超过收益；或
  构建本身快到分钟以内，全量反而省心。

## Quick Start

前置：Docker + act（`brew install act`）+ git（建仓与 diff 检测都靠它）；
catthehacker 镜像首次拉取后离线可跑。

```bash
cd cicd/13_monorepo
./monorepo_pipeline.sh                 # 全程四场景 + 断言
./monorepo_pipeline.sh bootstrap       # 建仓 + 首次全量（空树基准）
./monorepo_pipeline.sh scenario-a      # 只改 A：B/C 被 skip
./monorepo_pipeline.sh scenario-common # 改共享库：三模块全构建
./monorepo_pipeline.sh scenario-none   # 无变更重推：全 skip（幂等）
./monorepo_pipeline.sh clean           # 清临时仓库
```

三个场景的真机取证（完整输出见脚本运行日志）：

```
        [ok] affected 检测 = ["a"]
        [ok] a 构建执行
        [ok] b 被 skip（日志零行 + 无构建输出 + 产物未动）
        [ok] c 被 skip（日志零行 + 无构建输出 + 产物未动）
        [ok] affected 检测 = ["a","b","c"]
        [ok] 共享库变更扇出到全部依赖它的模块
        [ok] affected 检测 = []
        [ok] 产物字节级未动——重复触发零成本
```

诚实预期：act 0.2.89 对 `if=false` 的 job **完全静默**——真仓库上其
conclusion 是 `skipped`，本地以"零日志 + 产物未动"作证据。paths-filter
的 PR 语境需真仓库，本机主线用 push diff + `.last-built` 模拟同一语义。

## How It Works

### affected 闭包：diff、映射、反向闭包

`detect.sh` 三步：① `git diff --name-only` 拿变更文件；② 路径前缀映射
模块（`apps/a/*` → `a`）；③ 反向闭包——循环到不动点（反复扫描直到
不再有新模块），凡依赖受影响模块的模块一并加入（common 变 → 全体）。流水线自身变更保守触发全量。

### job 级 skip：条件在入口裁决

构建 job 声明 `needs: affected` 取 `outputs.modules`（JSON 数组），用
`if: contains(fromJSON(...), 'a')` 裁决。条件为假的 job 不产生日志、不
排队、不计费——这是"job 级 skip"与"step 里 if 跳过"的成本差异。

### 基准指针：只在成功后回写

`.last-built` 存上次成功构建的 commit，作为 diff 基准；无此文件退到空
树（首次全量）。流水线绿了才回写 HEAD——失败不污染基准，重试仍增量。
无变更重推时 diff 为空 → `affected=[]` → 全 skip，产物哈希对照字节级
未动（幂等断言）。

### 真仓库版：paths-filter

PR 语境下基准换成平台原生：`paths-filter` action 以 `pull_request` 的
base 为基准，输出各过滤器命中布尔值，job 用 `if: steps.filter.outputs.a
== 'true'`——机制与本地版一一对应，只是基准由平台提供。

## Pitfalls & Q&A

- **① act 不加 `--bind`，容器里没有仓库文件**：`bash detect.sh` 直接
  `No such file or directory`——非 bind 模式的 workspace 挂载不含仓库
  内容。凡 step 要读仓库文件的 act 实验，`--bind` 是必需品。
- **② grep 正则里 `[` 是括号表达式**：断言 `affected=["a","b","c"]` 时
  `[` 开启字符集，模式永远匹配不上字面量。含 `[]` 的固定格式断言用
  `grep -F`。
- **③ 闭包的单位必须一致**：`dep_of` 返回依赖**路径**（`libs/common`）、
  affected 集合存**模块名**（`common`），两者永不相等——闭包恒空、扇出
  静默失效。它不报错、不失败，只是"该构建的没构建"，只能靠断言抓。

Q&A：

- **为什么不用 paths-filter action 就地跑？** 它依赖 push/PR 事件的平台
  语境，act 本地模拟不完整。本地版用 `.last-built` 显式化"基准"这个概念，
  反而更适合教学——两者输出语义一一对应，迁移只是换基准来源。
- **依赖图怎么维护？** 小规模手工维护 + 断言兜底（本实验）；规模化用构建
  工具原生能力（Bazel/Turborepo/Nx 的 affected 命令）或 CODEOWNERS 近似。
  依赖图错一条边就是一次静默漏构建，所以任何实现都要配"扇出断言"。
- **skipped 和 failed 对 required check 的影响一样吗？** 不一样：GitHub
  的 branch protection 对 required check 的语义是"成功才可合并"，skipped
  默认不算失败——若把构建 job 设为 required，被 skip 时要用 `jobs.<id>.result`
  汇总判断，否则跳过 = 变相放行。
