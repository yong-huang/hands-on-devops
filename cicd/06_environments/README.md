# 06 · Environments 部署保护与审批流

> 生产部署不该"push 即生效"——environment 的 required reviewers（必须点击
> approve 放行的审批人名单）让 deploy job 卡在 pending 等审批，管理员也无法
> 绕过。
>
> 本实验推真仓库验证：push → run（workflow 的一次执行实例）卡 waiting →
> Web UI approve → 放行 success。REST API（通过 HTTP 请求访问的接口）的
> approve 端点（该接口下的一个 URL 地址）返回 404——Web UI 是唯一审批通道。

## Background

labs/16-20 的 CI（持续集成：推代码即自动构建测试）流水线都是"push 即部署"
——没有任何人可以拦截。当部署目标是生产环境时，一次误 push 就直接上线。

GitHub Environments 解决了这个问题：给 workflow（GitHub Actions 的自动化
流水线，定义在 `.github/workflows/` 下的 YAML 文件）的 job（流水线里一次
独立执行的任务单元）指定一个 environment。

在该 environment 上配置 required reviewers，job 就会在部署前卡住等待
审批。

本实验的 `workflows/deploy-approval.yml` 只有一行关键配置——deploy job
声明 `environment: production`。push 一个空 commit 后，这个 job 就会停在
waiting 状态，直到你在网页上点 approve。

审批人确认后（Web UI 点击 approve），job 才继续执行——整个过程在
deployments API（GitHub 用于记录每次部署及其状态变化的 REST 接口）里有
完整的留痕。

## What

**定义**：environment 是 workflow job 的一层"守卫"——引用它的 job 在执行前
必须通过该 environment 的 protection rules（审批人、等待时间、分支限制）。

| 部件 | 角色 |
|:---|:---|
| `environment: production` | job 引用名为 production 的 environment |
| `required reviewers` | 审批人列表：必须 approve 后 job 才继续 |
| `can_admins_bypass: false` | 管理员也不能跳过审批（默认 true，须显式关闭） |
| `gh api .../pending_deployments` | 查询当前卡在审批门的部署 |

可以把 environment 想象成一扇需要双人才能推开的门：推门的人（workflow 触发
者）在里面喊"我要出去"，门外有审批人确认后才开锁。

失效边界：与门不同的是，environment 门只拦"走流水线的 push"——直接在
服务器上手动操作不受它管控。且管理员默认可以跳过审批（`can_admins_bypass`
默认 true），必须显式关闭才强制走审批。

![Environments 部署保护与审批流](images/environments.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/06_environments/images/environments.html)（或本地打开 [`images/environments.html`](images/environments.html)）。

看图方法：左→右流水线：push 触发 deploy job → job 引用 environment 门 →
门右分两条路径——未审批时卡 waiting（实测），审批后放行 success。

## When to Use

- 生产环境部署需要人工确认：deploy job 卡 pending，审批后自动放行；
- 合规要求"每次部署都有审批留痕"：deployments API 记录完整状态链；
- 多环境分级管控：staging（预发布环境，上线前内部演练用）不设门（自动
  部署）、production 设门（需审批）。
- 怎么选：与 workflow_dispatch（手动触发，靠自觉）不同，environment 门对
  已 push 的代码强制拦截；与 PR review（管代码合入之前）不同，environment
  管部署执行之前——两者可叠加。
- 反例：单人项目的 dev 环境——审批门是团队协作的产物，单人只会添堵。

## Quick Start

前置：gh CLI（GitHub 官方命令行工具，已登录）、公共仓库。脚本第 18 行
`REPO=` 写死了仓库名——使用自己的仓库前先改成 `<你的用户名>/cicd-lab`。

```bash
cd hands-on-devops/cicd/06_environments   # 从仓库根出发
./environments.sh setup            # 创建 environment + 推 workflow
./environments.sh trigger          # 触发 deploy（应卡 pending）
./environments.sh assert-pending   # 断言 job 卡 waiting
# 此步需 Web UI 交互：gh run view --web 打开审批页面点 approve
# （脚本自带的 approve 步骤会因 REST 端点 404 而报错退出，见 Pitfalls ②）
./environments.sh assert-done      # 断言 job success + 状态历史
./environments.sh clean            # 删 environment（可选）
```

审批门的实测取证（gh api 真实输出）：

```
        …（assert-pending 横幅与空行略）
        run_id=39042936544
        job status: waiting
        pending deployment: …（详细 JSON 略）
        [ok] 环境审批门拦截成功：job 卡在 waiting
```

诚实预期：REST API 的 approve 端点返回 404——审批只能通过 Web UI 操作。
审批后 run 结论为 success，deployments API 留有完整状态链。

## How It Works

### environment 的创建与保护规则

```bash
gh api "repos/$REPO/environments/production" \
    --method PUT \
    --input - <<< '{"can_admins_bypass": false, "reviewers": [{"type": "User", "id": <用户ID>}]}'
```

`PUT` 是 upsert（存在则更新、不存在则创建）。`can_admins_bypass: false`
确保管理员不能跳过审批；`reviewers` 列表指定审批人。

不加 `can_admins_bypass: false` 时管理员直接绕过审批——实测首次创建时
job 秒完成、未卡 pending。

### 审批门的工作原理

job 声明 `environment: production` 后，GitHub 服务端在调度该 job 前先
检查 production environment 的 protection rules。

有 required reviewers 时服务端登记一条 pending deployment（一条"待审批"
的部署记录），job 停在 waiting——此时不占用任何 runner（GitHub 分配来执行
job 的虚拟机），直到审批人点击 approve。

### REST API approve 返回 404

REST API 文档列出了 `POST .../pending_deployments/{id}/review`
端点——但实测无论用哪个 ID 都返回 404。

GitHub 可能已将该端点迁移到 GraphQL（GitHub 的另一种按需查询式 API）
或仅限 Web UI。
这不影响实验：Web UI 审批后 run 正常放行。

## Pitfalls & Q&A

- **① `can_admins_bypass` 默认为 true**：首次创建 environment 后 push，job
  秒完成、不卡 pending——因为管理员跳过了审批。必须显式设为 false 并重新
  触发才能看到 waiting 状态。
- **② REST API approve 返回 404**：无论用哪个 ID，`.../pending_deployments/`
  下的 `review` 和 `approve` 端点都返回 404——审批只能通过 Web UI。
- **③ `per_page=1` 会取到错误的 run**：仓库里有其他 workflow 的 run
  （项目 02 的 fail-fast 等）——查 run 时必须按 workflow 名过滤。

Q&A：

- **environment 和 secret 有什么区别？** environment 是 job 级的守卫（控制
  "能不能跑"）；secret 是 job 级的参数（控制"用什么跑"）。两者可以配合：
  在 environment 上配置 secret，只有审批后才能解密。
- **一个 environment 能保护多个 workflow 吗？** 能：environment 按 repo
  级配置，所有引用该 environment 名的 job 都受同一套 protection rules 保护。
- **act 能模拟 environment 吗？** 不能：act（前几篇实验里本地模拟 GitHub
  Actions 的开源工具）0.2.89 没有 environments 概念——本实验必须推真仓库。
