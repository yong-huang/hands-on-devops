# 12 · 🏁 交付闭环：preview 门禁进 CI

> IaC（Infrastructure as Code，基础设施即代码：用代码声明云资源，由工具按
> 声明创建/修改环境）的最后一公里不是写完程序，是让它安全地过 CI（Continuous
> Integration，持续集成：代码合并前自动执行检查的流程）。
>
> 本实验把 10 号实验的 LocalStack 声明装进 act 本地回路（复用 CI/CD 系列的
> 成果）：preview --diff 作 PR 门禁展示变更，绿了才 `up` 部署；部署后再用
> `--expect-no-changes` 复核漂移——两次门禁都以退出码说话。
>
> 真仓库推送只是换个 runner（runner 即执行 job 的机器，届时换成 GitHub
> 托管的机器；选做）。

## Background

手跑 `up` 的时代，"改了什么"靠肉眼读进度条，"有没有漂移"靠运气。进 CI 后
这两件事必须自动化：合并前机器展示变更（人只做审批），部署后机器复核状态
（漂移立刻红）。

这一步做 complete（闭环），前面 11 个实验的成果才成为"能交付的能力"。

runner 用 act（在本机 Docker 里跑 GitHub Actions workflow 的工具，复用
CI/CD 系列 01 号实验验证过的回路）——不用推真仓库就能跑完整的 job 链；
LocalStack（在本机 Docker 里模拟 AWS API 的假云，实验 10 起复用）当目标环境。

CI 的 state 桶也放在 LocalStack 的 S3 里：本地与 CI 共用同一本账，呼应
实验 04 的"自建后端"。

## What

**定义**：两种门禁都是"以退出码说话"的 Pulumi 命令——`preview --diff`
只读地展示将发生哪些变更（展示型），`up --expect-no-changes` 要求执行后
无任何未声明变更（复核型，有漂移即非零退出）。

| 部件 | 角色 |
|:---|:---|
| `preview --diff` | PR 门禁：把变更条目亮出来给人审批，不执行 |
| `up --yes` | 部署：按 preview 的计划真正执行 |
| `up --expect-no-changes` | 漂移门禁：部署后立刻复核，发现账外变更即红 |
| act 三 job 链 | preview-gate → deploy → drift-gate，needs 串成交付流水线 |
| `--container-options -v` | 把二进制与插件的缓存卷挂进 job 容器（插件即 AWS provider 驱动：Pulumi 实际读写 AWS 资源的程序，数百 MB 只下一回） |

可以把流水线想象成闸机口的两道门：第一道门（preview）把"要改什么"亮在
屏幕上供人过目；过了第一道才放行执行（deploy）；执行完立刻再过一道感应门
（expect-no-changes）——有人绕过流程动过现场，第二道门会拦住他。

失效边界：门禁拦得住走流水线的人，拦不住绕过流水线的手——手工改动不会被
阻止，只会在下一次 drift-gate（变红）或 refresh（把现实同步回账本的对账
命令）跑起来时才暴露。

![两种门禁卡在部署前后](images/ci_delivery.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/12_ci_delivery/images/ci_delivery.html)（或本地打开 [`images/ci_delivery.html`](images/ci_delivery.html)）。

看图方法：中列竖排三个 job 组成交付链——门禁、部署、漂移复核依次向下；
左下 state 桶是本地与 CI 共用的账本（两条虚线是 job 对它的读写）。

## When to Use

- 团队要上"IaC 合并前必过门禁"的流程：本实验的 workflow 就是可推真仓库的
  起点模板（把 LocalStack 换成真环境、假凭证换成 OIDC（OpenID Connect：用短期令牌代替长期访问密钥的云认证方式）
  或密钥）；
- 防御"绕过流程的手工改动"：部署后 `--expect-no-changes` 一票否决；
- 多环境交付：同一 workflow 换 backend 与凭证参数，即可复制出 staging 版。
- 反例：单人单机的玩具栈（栈是同一份程序的一套独立配置+账本，本实验的
  dev 与 ci 就是两个栈），本地跑 `up` 前看一眼 preview 足矣，CI 门禁是团队
  协作的产物。

## Quick Start

前置：Pulumi CLI、Node.js 22、Docker、act、LocalStack CLI（需已配 auth
token，见 10 号实验；可用 `curl -fsS
http://localhost:4566/_localstack/health` 探活，未就绪脚本会自动拉起）。

aws 插件数百 MB：宿主与容器各装一次后永久缓存（容器侧走挂载卷）。

```bash
cd pulumi/12_ci_delivery
./ci_delivery.sh          # 完整生命周期：gate → act → clean
./ci_delivery.sh gate     # 本地验证两种门禁语义（--diff / --expect-no-changes）
./ci_delivery.sh act      # act 跑三 job 链路：preview 门禁 → deploy → 漂移门禁
./ci_delivery.sh clean    # 清两栈与资源桶（LocalStack 保留运行）
```

`gate` 段的门禁语义验证（真实输出，节选）：

```
        [ok] 退出码 0：期望态无漂移
                              ~ content  : "v1" => "v2"
          ~ releaseContent: "v1" => "v2"
        [ok] --diff 已亮出变更条目；配置还原 v1
```

`act` 段的三 job 链路（真实输出，节选）：

```
[pulumi-delivery/preview-gate] 🏁  Job succeeded
[pulumi-delivery/deploy      ] 🏁  Job succeeded
[pulumi-delivery/drift-gate  ] 🏁  Job succeeded
        [ok] 三 job 全绿：preview 门禁 → deploy → 漂移门禁（CI 内 state 也走 LocalStack）
```

诚实预期：首跑 act 要在容器内装 pulumi 二进制（约 1-2 分钟，网络差时会自动
回退下载源）；aws 插件数百 MB 由宿主下载后放进缓存卷再跑（见 Pitfalls ①）；
`clean` 段清资源桶与两栈，state 桶保留作后端资产。

## How It Works

### workflow：三个 job 串成交付链

```yaml
jobs:
  preview-gate:
    steps: [安装 pulumi, pulumi preview --diff --stack ci]
  deploy:
    needs: preview-gate
    steps: [pulumi up --yes --stack ci]
  drift-gate:
    needs: deploy
    steps: [pulumi up --yes --expect-no-changes --stack ci]
```

`needs` 让三个 job 依次执行：preview 红则后两个不跑。

CI 里的环境全部走 workflow 顶层 `env`：state 后端指向 LocalStack 的 S3
（带 endpoint 与 path-style 参数）、假凭证、独立口令——与本地实验共用同一
个 state 桶，"本地验证过的就是 CI 要跑的"。

### act 的四个本地参数（各踩一坑）

```bash
act --pull=false -P "ubuntu-latest=$IMG" --action-offline-mode \
    --network host \
    --container-options "-v $ACT_HOME:/root/.pulumi" \
    --bind -W ci/workflows/delivery.yml
```

- **flag 全放根层级**：0.2.89 的 `push` 子命令后解析不了这些 flag；
- **`-P`**：把 runs-on 标签映射到本机镜像；**`--pull=false`**：不强制重拉；
  **`--action-offline-mode`**：只用本地已缓存的 action；
- **`--network host`**：job 容器的 localhost 直达宿主端口的 LocalStack；
- **`--container-options "-v …"`**：act 顶层的 `-v` 已被 --verbose（调试日志
  开关）占用，卷挂载没有 `-v` 可用，只能把 docker run 参数整体传给
  `--container-options`（误写在事件位置会被当成事件名）；
- **`--bind`**：把工作目录 bind 进容器——`working-directory` 才有路径
  可切（非 bind 模式 act 只复制顶层，子目录直接 chdir 失败）。

### 两种门禁的语义边界

`preview --diff` 的价值是"把变更亮出来"——它不阻止任何人后续手改；
`--expect-no-changes` 的价值是"复核现场与账本一致"——部署后立刻再对一次账，
绕过流程的手工改动会在这一步红。

两个门禁一前一后，把"人审批什么"和"机器保证什么"分开。

## Pitfalls & Q&A

- **① 容器内插件下载会失败**：aws 插件数百 MB，容器内直连下到一半 EOF
  （实测 14 分钟 5 次全败）。正解：宿主 `curl -C - -L -o aws.tar <URL>`
  断点续传插件 tar（URL 是 `pulumi plugin install` 失败时打印的地址）。
- **①′** 解压进宿主目录
  `.act-cache/pulumi-home/plugins/resource-aws-v7.50.0/`——该目录会被
  `--container-options` 挂为容器内 `/root/.pulumi`。
- **② 续传拼接可能损坏文件**：拼接错位的二进制看似在位却起不来（`pulumi`
  报 exited prematurely）——`file` 看 ELF 头异常就是坏了，删掉重下一次；
  健康头是 `ELF 64-bit … statically linked`。
- **③ 两个栈别共用桶名**：本地 dev 与 CI 的 ci 是两个栈、两本账，桶名钉死
  会 `BucketAlreadyExists` 互相撞——桶名按栈名派生（`pulumi12-app-${stack}`）。
- **④ 清理 CI 栈要用 CI 的口令**：workflow 里的栈用独立
  `PULUMI_CONFIG_PASSPHRASE` 创建，本地脚本用主口令 destroy 它会报
  `incorrect passphrase`——口令也是栈资产的一部分。

Q&A：

- **act 三 job 全绿后，推真仓库还要改什么？** workflow 本身不动：换掉
  `env` 里的 backend 与凭证（真云走 OIDC 或加密 secret）、删掉
  `--container-options` 相关的本机参数。逻辑链路本实验已完整验证。
- **`--expect-no-changes` 和 `refresh` 什么关系？** 前者是"部署后断言无
  账外变更"的门禁（不动账本）；后者是把现实同步进账本的对账操作（实验 01
  的漂移自愈）。门禁发现漂移后，处置仍要靠 refresh + 人工决策。
- **为什么 state 桶也放 LocalStack？** 让"本地验证"与"CI 执行"共用同一本
  账（实验 04 的自建后端思路），且完全离线；真仓库场景把 backend 换成真
  S3/云后端即可，workflow 其余部分不变。
