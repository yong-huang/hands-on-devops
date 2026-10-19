# 08 · 流水线供应链加固

> `pull_request_target` 是 GitHub Actions 最危险的事件——fork PR（他人把
> 你的仓库复制一份到自己账号后，向原仓库发起的合并请求）的代码能以 base
> 分支（PR 想合入的目标分支）的权限执行，恶意 fork 可窃取 secrets。
>
> 本实验用 act（在本机 Docker 容器里跑 GitHub Actions 的开源模拟器）本地
> 取证"危险 workflow 的执行环境"，再用加固版对照验证隔离效果。三道防线：
> pull_request 替代 target、权限收敛、SHA pin（把 action 引用钉死在 40 位
> 十六进制提交哈希上——tag 可被篡改，SHA 不可变）。

## Background

labs/16-20 的 Gitea Actions 已做过基础 CI，但没碰到过 fork PR 的安全面。

GitHub Actions 的 `pull_request_target` 事件在 base 上下文运行（有
secrets——GitHub 加密保管、按需注入 workflow 的仓库凭据——和
GITHUB_TOKEN，即平台为每次运行自动签发的临时访问令牌），但允许 checkout
fork 分支的代码。

这等于用生产权限执行陌生人的代码。已知多起供应链攻击（不直接攻破你的
代码，而是污染构建依赖的第三方组件，如 CI 引用的 action）利用了这一漏洞。

## What

**定义**：`pull_request_target` 与 `pull_request` 的区别不在"谁来跑"而在
"在哪跑"：target 在 **base 上下文**（有 secrets 与 GITHUB_TOKEN），PR 在
**PR 上下文**（secrets 空、GITHUB_TOKEN 只读）。

| 部件 | 危险版（pull_request_target） | 加固版（pull_request） |
|:---|:---|:---|
| secrets | 可访问（base 的） | 空（fork PR 天然隔离） |
| GITHUB_TOKEN | `pull-requests: write`——能评论/关闭 PR，是攻击面 | 相同的显式收敛块——写权限已最小化，配合 PR 事件双保险 |
| 第三方 action | tag 引用 `actions/checkout@v4`（可篡改） | 不引用任何第三方 action（真仓库若引用，必须 40 位 SHA pin，扫描器兜底） |

可以把 `pull_request_target` 想象成"你把家门钥匙给快递员让他自己进门放
包裹"——快递员（fork）应该只把包裹放在门口，但你给了他进门的钥匙。

失效边界：这个类比只覆盖"权限发给了谁"，没覆盖平台的强制行为——
pull_request 事件下 secrets 隔离是 GitHub 强制的，不靠你自己锁门。

![流水线供应链加固](images/supply_chain.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/08_supply_chain/images/supply_chain.html)（或本地打开 [`images/supply_chain.html`](images/supply_chain.html)）。

看图方法：左上"危险路径"（实线）vs 左下"加固路径"（虚线）——fork PR 触发
两种 workflow，右上 SHA pin 扫描兜底，右下加固取证确认隔离生效。

## When to Use

- 仓库接受社区 fork PR：**必须**用 `pull_request` 而非 `pull_request_target`；
- workflow 使用第三方 action：用 SHA pin + Dependabot（GitHub 内置的依赖
  更新机器人，自动开 PR 升级依赖版本）自动更新到新 SHA；
- 需要限制 GITHUB_TOKEN 权限：`permissions` 收敛到 job 实际需要的最小集合。
- 反例：私有仓库只接受组织内成员 PR 且有 branch protection（分支保护规则：
  限制谁能直接 push、谁能合并）——风险较低，但仍建议 permissions 收敛。

## Quick Start

前置：Docker（act 在容器里跑 workflow，需先启动 daemon）、act（`brew
install act`，首次运行拉取 `catthehacker/ubuntu:act-latest` 镜像）、python3。

```bash
cd cicd/08_supply_chain
./supply_chain.sh              # 完整生命周期：dangerous → hardened → pin → clean
./supply_chain.sh dangerous    # 危险版取证：pull_request_target + 宽权限声明
./supply_chain.sh hardened     # 加固版断言：secrets 取不到 + 隔离生效
./supply_chain.sh pin          # SHA pin 扫描（第三方 action 引用检查）
./supply_chain.sh clean        # 清临时文件
```

预期现象：`dangerous` 段会打出红色 `❌` 与 `Job failed`——act 伪造的本地
仓库 fetch 不到 fork 代码，checkout 必然失败；脚本已兜住并降级为声明取证，
**报错不是实验失败**。`hardened` 段零外部依赖，应全绿。

`hardened` 段的隔离取证（act 真实输出）：

```
[hardened-pr/safe-check]   | ✅ 加固验证：
[hardened-pr/safe-check]   |   event: pull_request
[hardened-pr/safe-check]   |   GITHUB_TOKEN 权限范围（已收敛）
[hardened-pr/safe-check]   |   [ok] secrets 不可访问（fork PR 隔离生效）
```

`pin` 段的扫描取证（真实输出）：

```
[scan] 检查了 0 个第三方 action 引用
[ok] 所有第三方 action 引用均为 40 位 SHA（或可信前缀豁免）
…（.tmp/.github/workflows/ 第二次扫描结果相同，略）
```

诚实预期：危险版 checkout fork 代码这步在 act 本地必然失败（伪造仓库
fetch 不到 PR head 的 refspec），危险段只取证到声明层；加固版零外部依赖
可全绿。fork 代码真正被执行的行为，需推真仓库并从另一账号发 PR 验证。

## How It Works

### 危险面：pull_request_target 为什么危险

危险版 workflow 节选（与 `01_dangerous.yml` 一致）：

```yaml
on: pull_request_target      # ← 在 base 分支上下文运行
permissions:
  contents: read
  pull-requests: write       # ← 显式声明，但"写 PR"仍是攻击面
jobs:
  dangerous:
    steps:
      # 危险点：checkout PR head（fork 的代码）而非 base
      - uses: actions/checkout@v4          # ← tag 引用，可篡改
        with:
          ref: ${{ github.event.pull_request.head.sha }}
      - run: |
          echo "⚠️ DANGEROUS: running fork code with base permissions"
          echo "GITHUB_TOKEN scope: ${{ toJson(github.token) }}"
```

`pull_request_target` 与 `pull_request` 的区别不在"谁来跑"而在"在哪跑"：
target 在 **base 上下文**（有 secrets 与 GITHUB_TOKEN），PR 在 **PR 上下文**
（secrets 空、GITHUB_TOKEN 只读）。

危险版把两者混在一起——base 的权限 + fork 的代码 = 攻击面。

### 加固三件套

① **事件替换**：`pull_request_target` → `pull_request`——secrets 天然为空；
② **权限收敛**：两版均显式写 `permissions` 块演示最小集合写法；

③ **SHA pin**：第三方 action 用 40 位 SHA（不可变）替代 tag——加固版
干脆不引第三方 action，真仓库需要时才按此规则 pin。

`check_sha_pin.py` 扫描所有 workflow YAML——非 SHA 引用的第三方 action
全部报出（GitHub 官方 `actions/` 前缀豁免）。

### pin 扫描器的判定逻辑

扫描器区分四类 action 引用前缀：`actions/`（GitHub 官方，豁免）、`github/`
（豁免）、`gh`（豁免，但此规则过宽——owner 以 gh 开头的第三方也会被放行，
生产门禁应收紧为精确匹配）、`.`（仓库内本地 action，豁免）。

## Pitfalls & Q&A

- **① act 对 pull_request_target 支持有限**：危险版 checkout fork 代码这步
  在本地必然失败（act 伪造的仓库 fetch 不到 PR head 的 refspec）——本地
  验证覆盖声明层 + 加固版运行时，fork 代码被以 base 权限执行的行为只能
  推真仓库验证。
- **② pin 检查的 `gh` 前缀豁免过宽**：`TRUSTED_PREFIXES` 中的 `"gh"` 会把
  owner 名以 gh 开头的第三方 action 全部放行（如 `ghactions-xxx/...`）——
  生产门禁应收紧为精确匹配。

Q&A：

- **pull_request_target 就完全不能用吗？** 可以用，但必须遵守"不在 step
  里 checkout PR head"的铁律——只读 PR 元数据（标题、labels）是安全的；
  要跑 PR 的代码，用单独的 `pull_request` workflow 或 `workflow_call`。
- **SHA pin 怎么维护？** 在 dependabot.yml 配置
  `package-ecosystem: "github-actions"`——Dependabot 会发 PR 同时更新 SHA
  与注释里的版本号，人工审查后合并。
- **GITHUB_TOKEN 的权限怎么收敛？** workflow 顶层或 job 层设置
  `permissions:` 块——只声明 job 实际需要的权限，其余自动置 none。
