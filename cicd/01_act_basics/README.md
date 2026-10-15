# 01 · act 本地回路与 workflow 语法深潜：把 GitHub Actions 装进本机

> devops 系列的实验 18/20 里，CI 跑在 Gitea 中——改一行 workflow 要 commit→push→等 runner，迭代以分钟计。
> act 把 runner 搬进本机 Docker：`act -W` 秒级重放，secrets、artifact 服务、矩阵展开全部本地还原。
> 本实验立住 10 个语法特性，它是后面 15 个实验的"编辑器"——先有秒级回路，才有深水区。

## 1. 为什么需要它

GitHub Actions 的语法资料遍地都是，但"每次验证都要 push 到真仓库"把学习节奏拖到分钟级，
还把试错成本（红灯刷屏、烧 Actions 时长）押在了真仓库上。act 的价值主张：

- **同构执行**：workflow yml 原样喂给 act，job 容器、needs 调度、表达式求值与真仓库同一套语义；
- **秒级迭代**：改完 `act -W` 立即重放，语法试错从"分钟×推送"变"秒×本地"；
- **平台差异显形**：哪些行为 act 还原不了（concurrency 取消、timeout-minutes 强制、OIDC），
  本实验全部实测标注——知道边界才知道什么时候该上真仓库。

## 2. 总览：核心机制一图看懂

![act basics](images/act_basics.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/01_act_basics/images/act_basics.html)
> （或本地打开 [`images/act_basics.html`](images/act_basics.html)）。

看图方法：主路径从左到右——`-W` 装载 → 派生 job 容器 → steps 顺序执行 → 制品与日志落盘；
两条回流是 artifact 的 upload/download 回传与"日志留档 → 逐条断言"的取证回路；
右侧绕行进入 .logs 的虚线就是 fail 阶段的破坏注入——红灯也要有断言兜着。

## 3. 快速开始

```bash
cd cicd/01_act_basics
./act_basics.sh            # apply → observe → fail → clean 全程
./act_basics.sh apply      # 只跑 10 个语法特性（全绿断言）
./act_basics.sh fail       # 只跑三种破坏注入（该红就红的断言）
./act_basics.sh clean      # 清理本地产物
```

> **Docker 引擎**：本仓库脚本（`scripts/docker-env.sh`）默认 OrbStack 优先，Docker Desktop
> 也能跑（`DOCKERDESKTOP=1` 切回）。本实验在 OrbStack（arm64，engine 29.4.0）下全程验证。

真实输出（apply 段，关键节点）：

```
=====> [apply] 10 个语法特性逐个跑（首次约 1 分钟，之后秒级）
        [ok] 01_needs：NEEDS-OK
        [ok] 02_if：IF-OK
        [ok] 03_timeout：TIMEOUT-OK
        [ok] 04_concurrency：CONCURRENCY-OK
        [ok] 05_artifact：MD5-OK
        [ok] 06_secrets：SECRETS-OK
        [ok] 06_secrets：日志层打码、原值零泄漏
        [ok] 07_context：CONTEXT-OK
        [ok] 08_matrix：2×2 四个组合全部执行
        [ok] 09_defaults：DEFAULTS-OK
        [ok] 10_outputs：OUTPUTS-OK
```

fail 段（三种破坏，三种红灯证据）：

```
=====> [fail] 破坏注入①——篡改制品，md5 断言必须拦住
        [ok] 篡改被 md5sum -c 抓住，job 转红
=====> [fail] 破坏注入②——超预算 job 被强杀（step 层 timeout，秒级）
        [ok] 预算到点强杀（exit 124 取证），act 非 0 退出
=====> [fail] 破坏注入③——needs 断路器：上游红，test 被跳过，验尸官照跑
        [ok] test 被 skip（零执行痕迹），report 靠 always() 验尸（GitHub 语义忠实还原）
```

## 4. 核心概念

### 4.1 本地回路的四个参数

```bash
act --pull=false -P ubuntu-latest=catthehacker/ubuntu:act-latest \
    --artifact-server-path .artifacts -W workflows/01_needs.yml -s TOKEN=xxx
```

- `-P ubuntu-latest=镜像`：把 `runs-on` 标签钉到具体镜像——离线确定性的根基，
  配合 `--pull=false` 不碰远端 registry，断网也能重放；
- `--artifact-server-path`：upload/download-artifact 背后是 HTTP 制品服务，
  落盘目录指进实验目录，md5 对账才有原始证据可查；
- `-s KEY=value`：注入 secrets——注意它进的是 `secrets` 上下文而非进程环境（见 4.3）。

### 4.2 job 间传东西的三个通道

| 通道 | 语法 | 适合 | 实验文件 |
|:---|:---|:---|:---|
| 编排依赖 | `needs` + `if` | 控制执行顺序与断路 | 01、02、91 |
| 文件 | upload/download-artifact | 二进制、报告、镜像 tar | 05 |
| 标量 | `$GITHUB_OUTPUT` + `outputs` + `needs.xxx.outputs` | 版本号、开关、摘要 | 10 |

### 4.3 secrets 的两层语义（最容易误解的点）

打码发生在**日志输出层**，不是变量层：

```
| token=***
```

- 进程里 `$TOKEN` 是原值（程序正常使用），但打印到日志的任何内容都替换为 `***`；
- secret 必须显式映射才交到 shell 手上：`env: TOKEN: ${{ secrets.TOKEN }}`——
  `-s` 注入的值不会自动出现在进程环境，这是 GitHub 的正确语义，act 忠实还原；
- 反面含义：秘密一旦落进文件或 artifact，打码就罩不住了。

### 4.4 平台差异实测（act ≠ GitHub 的三处，2026-09-19 实测）

| 行为 | act 0.2.89 | GitHub 真仓库 | 本实验的处理 |
|:---|:---|:---|:---|
| `timeout-minutes` 强杀 | ❌ 不执行（sleep 120 跑满还绿） | ✅ 按分钟强杀 | step 层 `timeout` 命令演示同语义（90） |
| concurrency 取消旧 run | ❌ 单 run 无互斥场景 | ✅ 同组互斥/取消 | 语法解析验证，取消取证放实验 02 |
| `if: always()` 无视上游 | ✅ 忠实还原 | ✅ 同 | 91 的"验尸官"就是它 |

## 5. workflow 关键字段

```yaml
jobs:
  gen:
    outputs:
      version: ${{ steps.v.outputs.ver }}   # ② job 层声明，下游才取得到
    steps:
      - id: v                                # ① step 层产出必须带 id
        run: echo "ver=v1.2.3" >> "$GITHUB_OUTPUT"

  consume:
    needs: gen                               # ③ 下游经 needs 上下文取用
    if: always()                             # 无视上游成败——收尾专用，别挂发布动作
    steps:
      - run: echo "${{ needs.gen.outputs.version }}"

concurrency:            # workflow 级并发组（act 下仅语法验证）
  group: deploy-${{ github.ref }}
  cancel-in-progress: false
```

坑清单：

- **表达式与 shell 变量是两套语言**：`${{ }}` 解析期求值，`$GITHUB_*` 运行期取值；
  能拿到的东西也不同（`needs` 输出只有表达式可见）；
- **defaults.run.working-directory 不会 mkdir**：目录不存在第一步就炸；
- **矩阵 job 名带组合后缀**：`(3.11, slim)`——断言要按组合精确 grep；
- **bash 变量后别紧跟中文全角字符**：`$name：` 会把全角冒号的字节并进变量名
  （本实验主脚本就踩过，写 `${name}` 才稳）；
- **Ctrl-C 中断重来**：杀掉运行中的脚本后，当次 job 容器可能残留
  （`docker ps -a | grep '^act-'`），`docker rm -f` 清掉即可——正常跑完 clean 无残留。

## 6. 文件结构

```
01_act_basics/
├── README.md               # 本文件
├── act_basics.sh           # 主脚本：apply(10 绿)→observe→fail(3 破坏)→clean
├── workflows/              # 声明式配置：一个语法特性一个文件，全部 act 可重放
│   ├── 01_needs.yml        #   needs 依赖链：build→test→report
│   ├── 02_if.yml           #   条件执行：事件判断 + always() 收尾
│   ├── 03_timeout.yml      #   timeout-minutes 预算（act 下不强制，见 4.4）
│   ├── 04_concurrency.yml  #   并发组语法（取消语义在实验 02 云端取证）
│   ├── 05_artifact.yml     #   制品上传下载 + md5 完整性断言（带篡改注入口）
│   ├── 06_secrets.yml      #   secrets 注入、env 映射与日志打码
│   ├── 07_context.yml      #   表达式上下文 + env 三层覆盖
│   ├── 08_matrix.yml       #   2×2 矩阵组合
│   ├── 09_defaults.yml     #   默认 shell 与工作目录
│   ├── 10_outputs.yml      #   outputs 三级接力传值
│   ├── 90_timeout_kill.yml #   [fail] 超预算击杀：exit 124 取证
│   └── 91_needs_fail.yml   #   [fail] 断路器：test 被跳、验尸官照跑
└── images/                 # 架构图三件套（图源/交互版/双主题 SVG）
```

## 7. 深入要点

**Q1：act 既然能本地跑，真仓库还有必要吗？**
有。三件事本地永远做不了：concurrency 取消（需要服务端 run 队列）、environments 审批与
OIDC 签发（需要 GitHub 服务端）、真实缓存加速（actions/cache 的服务端存储）。
正确姿势：本地 act 管"写得对"，真仓库管"跑得通"——实验 02 起每个 ☁️ 实验都按此分工。

**Q2：为什么 `-s` 注入的 secret 在 shell 里读不到？**
GitHub 的设计里 secret 存在于独立的 `secrets` 上下文，出于最小暴露原则不进进程环境；
要用必须显式映射 `env: X: ${{ secrets.Y }}`。act 同构了这个语义——这同时解释了
为什么日志打码是输出层的字符串替换，而不是变量层的魔法。

**Q3：`if: always()` 和不写 `if` 的 job，在上游失败时差在哪？**
不写 `if` 等价 `if: success()`——上游失败则 skipped，连容器都不起（断路器）；
`always()` 无视上游状态照跑——这是"验尸官"语义（清理、告警、取证）。
91 实测最容易踩的坑：把发布动作挂上 always()，上游红了部署照跑。

**Q4：act 的红灯可信吗？会不会"本地红、云端绿"？**
编排语义（needs/if/矩阵/表达式）两者同构，红灯可信；环境差异集中在 runner 镜像
（catthehacker ≠ GitHub 托管的 ubuntu-runner 镜像，预装工具不同）。对策：断言只依赖
workflow 自己产出的东西（标记、md5、退出码），不依赖镜像里恰好装了什么。

**Q5：为什么主脚本断言 grep 日志文件而不是 grep 活管道？**
`grep -q` 命中即退出，会把上游 `tee` 挤成 SIGPIPE，`pipefail` 下偶发"明明全绿却断言
失败"。先跑完留档、再对文件断言，是日志取证类脚本的通用稳态写法。

## 8. 总结

本实验把 GitHub Actions 的执行引擎装进了本机：10 个语法特性全部落成可重放的 workflow，
三种破坏注入全部有红灯断言兜底，act 与真仓库的三处差异实测标注、各给了处理姿势。
秒级迭代回路就此成型——cicd 后面 15 个实验的所有 workflow 都先在这里打磨，再上真仓库。

下一篇（02 · 矩阵构建与并发治理）：矩阵的 include/exclude 裁剪、fail-fast 的两种取舍、
concurrency 取消的真仓库取证——本实验 4.4 挂起的两个"act 做不了"，到那儿收账。
