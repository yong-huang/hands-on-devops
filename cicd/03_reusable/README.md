# 03 · 可复用工作流与复合动作

> staging 和 prod 两条流水线 90% 的逻辑相同，复制粘贴的代价是改一处要同步 N 处
> 还容易漏。workflow_call 把共享逻辑封装成可复用 workflow（带 inputs/secrets/
> outputs），caller 只传参数；composite action 把多步操作封装成"宏"在 job 内
> 原地展开。改 callee 一处，两条流水线同步生效——本实验实测取证。

## Background

labs/18-20 的 Gitea Actions（Gitea 平台的 GitHub Actions 兼容 CI）已做过
基础 CI（持续集成：推代码即自动构建测试），那时的 workflow 都是自包含的——
每个 `.yml` 文件里从 checkout 到 deploy 写全。

当 staging 与 prod 的构建逻辑 90% 相同时，你面对两个选择：接受复制粘贴
（改 lint 规则要同步两个文件），或者找一个复用机制。

GitHub Actions 提供两种粒度的复用：workflow_call 把整个 workflow 变成可被
`uses:` 调用的"子程序"（带 inputs/secrets/outputs 接口）；composite action
把多个 step 打包成一个"宏"，在调用方的 job 内原地展开。

两种复用的接口语法与 labs/18 的 Gitea Actions 同构——迁移零成本。

## What

**定义**：workflow_call 是 workflow 的一种触发器——加上它后，workflow 可被
其他 workflow 通过 `uses:` 调用，调用方（caller）传参数，被调方（callee）
执行共享逻辑并回传 outputs。

composite action 是用 `action.yml` 声明的多步"宏"，在 caller 的 job 内
原地展开（共享容器与文件系统）。

| 部件 | workflow_call | composite action |
|:---|:---|:---|
| 粒度 | 整个 workflow（多 job） | 多个 step（单 job 内） |
| 运行环境 | 独立容器 | caller 的容器（原地展开） |
| 接口 | `inputs` + `secrets` + `outputs` | `inputs` + `outputs` |
| 引用方式 | `uses: ./.github/workflows/xx.yml` | `uses: ./actions/xx` |
| 适合封装 | 构建 + 测试 + 上报的完整链路 | 打标签 + 探活等重复 step 序列 |

可以把 workflow_call 想象成"外包团队"——你发需求（inputs）、给凭证
（secrets）、收报告（outputs），团队在你看不到的独立环境里干活。
失效边界：与外包不同的是，callee 的 job 日志仍出现在
 caller 的 run 里，且 inputs 类型错误会被直接拒收。

composite action 则是"多合一工具"——在你自己的工位上展开，共享你的桌面
和文件。失效边界：composite action 不支持 `secrets` 上下文（凭证只能通过
`env` 间接传递），也不启动独立容器——需要隔离时用 workflow_call。

![可复用工作流与复合动作](images/reusable.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/03_reusable/images/reusable.html)（或本地打开 [`images/reusable.html`](images/reusable.html)）。

看图方法：两条业务流水线（staging/prod）各自通过 `uses:` 调用同一个 callee
（传不同 inputs），再用 composite action 做部署后探活——改 callee 的共享
逻辑，两条流水线同步生效。

## When to Use

- 多环境（staging/prod/preview）共享同一套构建 + 测试逻辑——只写一次 callee；
- 多仓库复用同一套流程——callee 放独立仓库，caller 按版本引用（`@v2`）；
- 多个 job 重复相同的 3-5 个 step——composite action 消除 step 级重复。
- 反例：只有一个 workflow 用得到的逻辑，内联更直观；composite action 需要
  secrets 时（它不支持 `secrets` 上下文），改用 workflow_call。

## Quick Start

前置：Docker 已启动、act（`brew install act`）。
容器镜像，新机器需先
`docker pull catthehacker/ubuntu:act-latest` 预取（脚本用 --pull=false，
不会自动拉取）。

```bash
cd hands-on-devops/cicd/03_reusable   # 从仓库根出发
./reusable.sh           # 完整生命周期：probe → run → share → clean
./reusable.sh probe     # 探活：act 0.2.89 能否跑 workflow_call + composite
./reusable.sh run       # 跑两条业务流水线，断言 outputs 与上下文传递
./reusable.sh share     # 改 callee 一处 → 重跑两条流水线 → 断言同步生效
./reusable.sh clean     # 清日志与临时文件
```

`run` 段的两条流水线验收（act 真实输出，节选）：

```
[deploy-staging/deploy    ]   | [ok] greeting 指向 staging
[deploy-prod/deploy    ]   | [ok] greeting 指向 production
```

`share` 段改 callee 一处（追加 SHARED_V2 标记）重跑两条流水线，两条日志
均出现该标记——"改一处处处生效"取证通过。

诚实预期：act 0.2.89 不支持本地 composite action（`uses: ./path` 找不到
`action.yml`），本地版将 composite 的逻辑内联到 deploy 步骤验证同等链路；
composite action 本体推真仓库后可直接使用（语法同构）。

## How It Works

### callee：workflow_call 的接口三件套

```yaml
on:
  workflow_call:
    inputs:
      environment: { type: string, required: true }
      run_lint:    { type: boolean, default: true }
    secrets:
      deploy_token: { required: true }
    outputs:
      build_id:
        value: ${{ jobs.build.outputs.build_id }}
```

`inputs` 是类型化的参数（string/boolean/number），caller 传错类型会被拒。

`secrets` 是显式声明的凭证通道（callee 内用 `${{ secrets.deploy_token }}`
读取）。

`outputs` 是 callee 向 caller 回传数据的接口——值取自 job 的 output，
caller 通过 `needs.build-test.outputs.build_id` 消费。

### caller：同一 callee，不同参数

staging 传 `environment: staging, node_version: "22"`；prod 传
`environment: production, run_lint: false`——差异只在参数。

`share` 段在 callee 的 build step 追加 `[SHARED_V2]` 标记，重跑两条
流水线后两条日志均出现该标记——"改 callee 一处，caller 同步生效"取证通过。

### composite action：job 内的多步"宏"

`actions/hello-composite/action.yml` 声明了三个 step（echo + check +
print）和两个 outputs（greeting + status）。

`runs.using: composite` 标记其类型。caller 在 job 内
`uses: ./actions/hello-composite` 原地展开——共享文件系统，不启动新容器。

## Pitfalls & Q&A

- **① act 0.2.89 不支持本地 composite action**：`uses: ./actions/xx`
  报 `file does not exist`——composite action 推真仓库后可用；本地验证时
  将同等逻辑内联为普通 step。
- **② workflow_call 的 callee 必须在 caller 的 `.github/workflows/` 下**：
  act 的 workspace 是 git 仓库根——实验用临时 git 仓库搭出正确结构再跑。
- **③ step 内读自己的 output 是空串**：`GITHUB_OUTPUT` 写入的值要到下一个
  step 才能通过 `steps.xx.outputs` 读取——同 step 内用 shell 变量。

Q&A：

- **workflow_call 和 composite action 怎么选？** 跨 job/多 job 链路用
  workflow_call（独立环境隔离依赖）；单 job 内重复 step 序列用 composite
  action（轻量、共享文件系统）。需要 `secrets` 时只能用 workflow_call。
- **callee 改了会自动影响 caller 吗？** 用 `uses: ./.github/workflows/xx.yml`
  引用本地文件时是——caller 每次跑都读最新 callee。用 `uses: org/repo@v2`
  引用远端时——钉在版本 tag 上，改 callee 后要打新 tag 才生效（版本引用
  策略）。
- **act 的 workflow_call 和 GitHub 的差在哪？** act 0.2.89 支持
  workflow_call 的基本调用与参数传递；composite action 的本地引用是已知
  不支持项——两者都推真仓库后行为一致。
