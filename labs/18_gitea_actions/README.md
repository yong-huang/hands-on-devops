# 18 · Gitea + Actions：轻量 Git 平台自带 CI

> Jenkins 是"平台带 CI"，Gitea 是"Git 平台自带 CI"：仓库、PR、流水线一个二进制全包。
> workflow 用 GitHub Actions 兼容语法——本地练完直接懂 GitHub Actions。本实验自带
> Gitea + act_runner，push 一次代码，流水线自动触发，红灯自动现形。

## 1. 为什么需要它

Jenkins 强大但重（controller/agent/插件生态）。Gitea Actions 的价值主张：

- **一体机**：git 服务 + CI 调度 + 制品/PR 集成，一个容器加一个 runner；
- **语法兼容**：.gitea/workflows/*.yml 与 GitHub Actions 同构，迁移零学习成本；
- **push 即触发**：没有 job 配置步骤，`on: push` 写在仓库里。

## 2. 总览：核心机制一图看懂

![gitea actions](images/gitea_actions.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/18_gitea_actions/images/gitea_actions.html)
> （或本地打开 [`images/gitea_actions.html`](images/gitea_actions.html)）。

看图方法：runner 用 registration token 注册到 Gitea；push 含 workflow 的提交后，
Gitea 按 runs-on 标签派发 job，runner 执行并把每步状态回传——commit 上的 ✓ 就是
PR 页面看到的 checks。

## 3. 快速开始

```bash
cd labs/18_gitea_actions
./gitea_actions.sh            # apply（push→全绿）→ fail（注入红灯）→ clean
```

真实输出（关键节点）：

```
=====> [apply] 等待流水线执行并断言结果
        run #1: SUCCESS
        [ok] push 自动触发全绿 run=1
=====> [fail] 注入失败用例（workflow 里 exit 1）
        run #2: FAILURE
        [检出] 流水线红（注入的 assert 被抓住）
        [ok] 已 revert 修复并重新推送
```

## 4. 核心概念

### 4.1 三个角色：Gitea、runner、workflow

- **Gitea**（`GITEA__actions__ENABLED=true` 开关）：存仓库、解析 workflow、派发 job；
- **act_runner**：用 registration token 注册，按 `runs-on` 标签认领 job，docker 模式下
  每个作业是独立容器；
- **workflow**：`.gitea/workflows/*.yml`，`on: push` 触发，步骤与 Actions 语法一致。

### 4.2 runner 的两种执行模式

| 模式 | 标签 | 作业跑在哪 | 本实验 |
|:---|:---|:---|:---|
| docker | `lab:docker://镜像` | 每步一容器（需挂 docker.sock） | 先用后换 |
| host | `lab:host://` | runner 容器自身 | 最终采用 |

坑：macOS 的 Docker Desktop 上，把宿主 `~/.docker/run/docker.sock` 挂进容器**不可行**
（unix socket 文件无法经 virtiofs 共享）；`/var/run/docker.sock` 这条 VM 内路径才可以。
而高负载下 docker copy 偶发"Network error"——host 模式彻底绕开（作业直接跑在 runner
容器里，runner 镜像加了 python3/git）。

### 4.3 状态判据：从哪拿到"绿/红"

Gitea 1.22 没有 actions REST API（1.23 才加）。本实验的判据是 gitea 数据目录里的
运行日志：`/data/gitea/actions_log/<owner>/<repo>/<NN>/<run>.log`，结尾必有
`🏁 Job succeeded` 或 `🏁 Job failed`——**确定性强，不受页面侧栏混排干扰**。

### 4.4 红灯闭环

fail 步骤往 workflow 注入 `exit 1` 步骤 → push → 新 run 红灯 → revert 修复 → 再推回绿。
注入的位置有讲究：改 app.py 没用（流水线没执行它），必须注入 workflow 本身——
"测试的失败要发生在被测系统里"。

## 5. YAML 关键字段

```yaml
on:
  push:
    branches: [main]        # 只在 main 上触发，feature 分支不跑

jobs:
  test-and-build:
    runs-on: lab            # 匹配 runner 的 labels（lab:host:// 或 docker://镜像）
    steps:
      - run: python -V      # 不写 uses: → 零外部依赖（actions 源在 gitea.com/github）
```

坑清单（全部真实踩过）：

- **坑① runner 注册**：token 经 `gitea actions generate-runner-token` 生成；
  gitea CLI 必须 `-u 1000` 执行（root 被拒，实验 05 同坑）；
- **坑② socket 挂载**：见 §4.2，macOS 专属陷阱；
- **坑③ 1.22 无 actions API**：状态判定从 gitea 数据目录的运行日志读，
  且日志结尾的标记是确定性的；
- **坑④ 页面侧栏混排**：actions 页面的 Success/Failure 字样混有其他 run 的状态，
  按"取第一个匹配"判定会误判；
- **坑⑤ max_run 的 pipefail**：还没有任何 run 时 grep 退出码 1 会杀死脚本——
  数值兜底 `echo 0`。

## 6. 文件结构

```
18_gitea_actions/
├── README.md                        # 本教程
├── gitea_actions.sh                 # apply / fail / clean（含状态判定）
├── repo/                            # 推到 Gitea 的演示仓库
│   ├── .gitea/workflows/release.yml # workflow（push 触发）
│   └── app.py                       # 业务代码
├── runner/
│   ├── Dockerfile                   # host 模式 runner 镜像（python3+git）
│   └── config.yaml                  # runner 配置（labels + 日志级别）
└── images/                          # 图三件套（json/html/svg）
```

## 7. 面试要点

- **Gitea Actions 与 GitHub Actions 的兼容边界？** workflow 语法/缓存/ARTIFACT 兼容；
  差异在生态：`uses:` 的 action 市场默认指向 gitea.com，私网需自建 mirror 或纯 run 步骤。
- **runner 注册与安全边界？** registration token 只管注册；注册后 runner 与 server 走
  长轮询。runner 是"受信执行环境"——能碰 secrets 的东西必须自己人部署。
- **docker 模式与 host 模式的取舍？** docker 模式隔离好、环境干净；host 模式零
  daemon 依赖、适合受限环境（本实验因 macOS socket 共享限制选择 host）。
- **push 触发的 CI 如何防止"无限触发"？** CI 生成的提交用 [skip ci] 标记或专用
  token 推送不触发 workflow。

## 8. 总结

Gitea Actions 证明了"CI 可以是 Git 平台的原生器官"。实验 19 用 Woodpecker——容器
原生 CI 的极简派——跑同一条发布流水线，然后实验 20 把完整 CI/CD（含门禁）定型。
