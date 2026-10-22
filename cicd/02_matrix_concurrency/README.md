# 02 · 矩阵构建与并发治理

> 同一份代码要在 3 个 Node 版本 × 2 个 OS 上验证，手写 6 条几乎相同的 job（GitHub Actions 中一次独立的构建任务，定义在
> workflow 文件里，多个 job 并行执行）
> 既冗长又易漏改；推了新 commit 发现旧构建还在跑，算力被浪费。
>
> 矩阵（strategy.matrix）把 N 种组合声明成一张表，include/exclude 裁剪
> 取舍；concurrency group 让服务端自动取消过时的 run——两者都以退出码与
> API 状态可验证。

## Background

没有矩阵的时代，多版本验证靠复制粘贴 job：每加一个 Node 版本或 OS 就多一段
几乎相同的 YAML，改一处脚本要同步改 N 处。跑了新 commit 发现旧构建还在占
runner（实际执行 job 的机器），手动取消又容易漏——这些是矩阵与并发治理要解决的原始痛点。

GitHub Actions（GitHub 内置的持续集成服务：仓库收到 push 后按 workflow
文件自动跑任务）用 `strategy.matrix` 把 N 种组合声明成一张参数表。

服务端的执行引擎（解析 workflow 并调度 job 的组件）按表展开成 job；
include/exclude 在表上做加法与减法。

`concurrency group` 则是服务端的"同组只跑最新的"语义——新 run（一次
workflow 从触发到结束的执行实例）进来，同组的旧 run 自动 cancelled。

本实验在 act（在本机 Docker 容器里模拟运行 GitHub Actions workflow 的
开源命令行工具）本地验矩阵展开与 fail-fast（一个组合失败时是否取消其余组合）的 false
取值语义。

推真仓库（公共免费）验 true 的取消与 concurrency group——这两者是服务端
行为，act 模拟不了。

## What

**定义**：strategy.matrix 是声明式的多组合展开——一张参数表生成 N 个 job；
fail-fast 控制一个失败时是否传染（取消其余）；concurrency group 是服务端
按组互斥——同组新 run 开始，旧 run 自动 cancelled。

| 部件 | 角色 |
|:---|:---|
| `strategy.matrix` | 参数表：os × node 的每种排列生成一个 job |
| `matrix.exclude` | 减法：裁掉不需要的组合 |
| `matrix.include` | 加法：补回或追加带额外标记的组合 |
| `strategy.fail-fast` | `true`（默认）：一个失败即取消其余；`false`：跑完全量再汇总 |
| `concurrency.group` | 同组互斥：新 run 开始，旧 run 被 cancelled |

可以把矩阵想象成考卷印刷：一张参数表（版本 × 语言）自动印出 N 份不同卷；
exclude 是"这科不考了"的裁剪，include 是"这科加个附加题"的补回。

失效边界：考卷一次印好互不影响，矩阵 job 却可能被 fail-fast 中途取消，
include 还能给组合追加卷面上没有的属性——这两点比喻覆盖不到。

![矩阵展开与并发取消](images/matrix_concurrency.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/02_matrix_concurrency/images/matrix_concurrency.html)（或本地打开 [`images/matrix_concurrency.html`](images/matrix_concurrency.html)）。

看图方法：左边矩阵表展开出 6 个组合（exclude 裁掉 macos+18 后 include 补回
并打上 experimental 标记）；右边 concurrency group 在服务端做互斥——新 run
进组，旧 run 自动 cancelled。

## When to Use

- 同一份构建/测试脚本要在多版本、多 OS、多架构上验证；
- CI（持续集成，推代码即自动构建测试）算力宝贵：功能分支连推时旧构建应该
  被取消，只跑最新的；
- 排查"只在某个版本上才有的 bug"：fail-fast: false 跑全量，收集所有失败点
  再一起修（而非修一个等一轮）。
- 反例：只有一种构建环境的仓库，矩阵是过度设计；单人快速迭代场景，
  concurrency 取消反而可能丢掉你想留的中间产物。

## Quick Start

前置：Docker 已启动、act（`brew install act`，GitHub Actions 本地模拟器）。

新机器需预取容器镜像（脚本用 --pull=false，不会自动拉取）：
`docker pull catthehacker/ubuntu:act-latest`。

gh CLI：`brew install gh && gh auth login`（GitHub 官方命令行工具，已登录）。

act 部分纯离线；cloud 部分推真仓库（公共免费）并调用 gh api 取证。

```bash
cd hands-on-devops/cicd/02_matrix_concurrency   # 从仓库根出发
./matrix_concurrency.sh           # 完整生命周期：matrix → failfast → cloud → clean
./matrix_concurrency.sh matrix    # act 跑矩阵展开，断言 6 个组合在册
./matrix_concurrency.sh failfast  # 本地验 fail-fast: false 语义（true 推真仓库）
./matrix_concurrency.sh cloud     # 真仓库：fail-fast 取消差异 + concurrency 取消
./matrix_concurrency.sh clean     # 清日志与制品
```

`matrix` 段的 6 个组合逐一在册（act 真实输出，节选）：

```
[matrix-basic/build-1]   | os=ubuntu-latest node=18 experimental=
[matrix-basic/build-2]   | os=ubuntu-latest node=20 experimental=
[matrix-basic/build-3]   | os=ubuntu-latest node=22 experimental=
…（ubuntu/mac 另两组略）
[matrix-basic/build-6]   | os=macos-latest node=18 experimental=true
```

`cloud` 段在真仓库上的取证（真实输出）：

```
        concurrency-demo  completed/cancelled
        concurrency-demo  completed/success
        failfast-false  completed/failure
        failfast-false  completed/failure
        failfast-true  completed/failure
        failfast-true  completed/failure
```

fail-fast: true 的 job 级取消（gh api 实测：failure=1, cancelled=3）；
fail-fast: false 的 job 级结果（gh api 实测：success=2, failure=2,
cancelled=0）。

诚实预期：act 里 macos-latest 映射为 Linux 容器（验矩阵逻辑非 OS 差异）；
act 0.2.89 的 fail-fast: true 有怪癖——成功 job 也被标 failed（step 级
输出不受影响），真取消语义在真仓库取证。

cloud 段首次运行需网络推送 GitHub，之后利用 gh api 幂等取证（幂等：重复
执行结果不变——按 concurrency-demo 自己的 run 数（≥3）判定是否跳过推送，全仓库 run 总数不影响）。

## How It Works

### 矩阵展开与 include/exclude

```yaml
matrix:
  os: [ubuntu-latest, macos-latest]
  node: [18, 20, 22]
  exclude:
    - { os: macos-latest, node: 18 }
  include:
    - { os: macos-latest, node: 18, experimental: true }
```

2 OS × 3 node = 6 个排列；exclude 裁掉 macos+18（余 5）；include 补回并
追加 experimental 标记（回到 6）。

每个 job 的步骤里用 `matrix.os` 等变量取当前组合的值——脚本只写一份，
组合间的差异全在声明层。act 实测 6 个组合逐一在册，experimental=true
只出现在 include 补回的组合上。

### fail-fast 的两种语义边界

fail-fast: false 时所有组合跑完再汇总（本地 act 实测：2 FAILED + 2 done
cleanly，失败不传染）。

true 时服务端取消其余 in-progress job——真仓库 gh api 实测：failure=1,
cancelled=3。act 0.2.89 模拟不了取消（它把成功 job 也标 failed），这就是
"矩阵本地验，取消真仓库验"的原因。

### concurrency group：服务端互斥

```yaml
concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: true
```

`group` 按分支隔离：同分支连推，新 run 开始时服务端自动 cancel 旧 run。

真仓库实测：第一次 run `completed/cancelled`、第二次 `completed/success`。
`cancel-in-progress: false`（默认）则新 run 排队等待——适合"每次构建都要
留档"的场景。

## Pitfalls & Q&A

- **① act 里 macos-latest 跑的是 Linux**：`-P` 把 runs-on（workflow 里
  声明 job 跑在哪种机器上的字段）标签映射到本机容器镜像——OS 矩阵值只是
  变量，真实 OS 差异要真仓库才有。
- **② act 0.2.89 的 fail-fast: true 怪癖**：一个失败后所有 job（含成功的）
  结论都标 failed——step 级输出（`done cleanly` / `FAILED`）不受影响，
  断言应取 step 级证据而非 job 结论。
- **③ git push 与 gh api 走不同通道**：git 到 github.com:443 可能超时
  而 gh api 正常（API 走不同端点）——cloud 段按「本 workflow 已有 run 则跳过推送」
  实现幂等。

Q&A：

- **exclude 和 include 的执行顺序？** 先全排列 → exclude 做减法 → include
  做加法（可追加原表中没有的属性如 experimental）。
- **concurrency 不加 cancel-in-progress 会怎样？** 同组新 run 排队等旧 run
  结束——适合"每次构建都要留档"的审计场景。
- **act 的 fail-fast 和 GitHub 的差在哪？** act 0.2.89 只是"一个失败就终
  止 run"（成功 job 也标 failed）；GitHub 是精确的 job 级取消——被取消的
  job 结论明确标 `cancelled`，gh api 可断言数量。
