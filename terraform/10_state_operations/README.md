# 10 · state 操作全家桶：纳管、改名与摘除

> Terraform（用声明式配置文件创建和管理基础设施的开源工具）的 state（账本：记录"哪些资源归我管、它们现在的属性"）与引擎里的真实资源是两个世界。
>
> 本实验用一台手工创建的容器，走完资源身份的四段旅程：纳管、改名、摘除、收编（收编 = 无主资源再次被 import 接管，对应图中摘除后指回已纳管的虚线，Q&A 展开），全程 plan 断言护航。跑完 `./state_operations.sh all`（约 4 分钟）得到 17 条断言全过的记录。

## Background

引擎里早就有了一台容器——某次紧急事故里手工 `docker run` 拉起来的，跑了两周没人敢动。这份"存量"在 Terraform 看来是不存在的：下一次 apply 可能创建一台同名容器直接撞死它。

没有纳管手段之前，人们只能二选一：放弃 Terraform 继续手工管理——真实环境从此与任何配置记录对不上、越走越远，这正是配置漂移（基础设施实况与配置记录渐行渐远）的起点，或者删掉重建（对有状态服务不可接受）。Terraform 的答案是补齐账本而不是动引擎：import 家族把存量资源"登记"进 state。

登记的手段在演进：TF 1.1 提供 moved block 声明资源改名，1.5 提供 import block（纳管进配置文件，可 review）与配置生成（照账本实况自动写出资源体）；命令行的 state mv 则是改名的手工等价物。本实验把这四件各跑一遍，并验证两条改名路互相等价。

## What

state 操作的三个动作都是"改账本、不动引擎"：纳管（import）把引擎里已有的资源登记进账本；改名（moved / state mv）只换账本里的资源地址；摘除（state rm）把记录从账本抹掉——实体原地不动。

可以把 state 想象成仓库的台账：import 是给库存里已有的货物补登记，moved 是把货物记到新货架页签，state rm 是把一行记录划掉。但台账划掉一行不等于货没了——货还在仓库里，只是从此没人管它，这就是最容易被误解的一点。

资源身份的四段旅程与两个危险面（改名时配置与 state 只动一边会触发重建；摘除后同名资源会被"重建"而冲突）：

![资源身份四状态](images/state-ops.lifecycle.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/terraform/10_state_operations/images/state-ops.lifecycle.html)
> （或本地打开 [`images/state-ops.lifecycle.html`](images/state-ops.lifecycle.html)）。

## When to Use

| 场景 | 用什么 |
|:---|:---|
| 紧急手工创建的资源要转正，纳入统一管理 | import block + 配置生成 |
| 重构配置结构：资源搬家（换模块、换名字），但不许重建 | moved block（或 state mv） |
| 确认某资源不再归 Terraform 管（转交其他工具/团队） | state rm 摘除，随后处理实体 |

何时不用：能随时重建的无状态资源，直接 destroy + apply 重建更干净，不必走 import；批量重排整个配置库时，先把目录结构定稳再动账本，避免反复 moved。

两对工具的选择：

- **import block vs 命令行 import**：block 写进配置可 review、可进 PR（代码评审合并流程）、可批量，纳管完要移除声明；命令行是一次性手工操作，即敲即生效，适合单台快速处理。
- **moved block vs state mv**：moved 是声明式（进配置，重构意图有历史可查）；state mv 是命令式（即时生效）。两者等价，配置库里的重构建议用 moved 留痕。

## Quick Start

前置条件：

- Terraform ≥ 1.5（import block 与配置生成需 1.5+；moved block 需 1.1+）
- Docker（作者在 macOS 的 OrbStack 上实测），本机有 alpine:3 镜像（缺失会自动拉取）
- provider 经仓库内置镜像源安装：脚本自动 source `scripts/tfrc.sh`，不访问外网

```bash
./state_operations.sh all        # 七步一条龙：up → import → moved → statemv → rm → verify → clean
```

真实输出（节选，`......` 为省略）：

```text
=====> [import] 纳管：import block + 配置生成（TF 1.5+ 的现代路线）
        Plan: 1 to import, 2 to add, 0 to change, 1 to destroy.
......
        [ok]   plan 识别到 1 个待纳管资源（1 to import）
        [ok]   配置生成落地（generated.tf 已写出资源体）
        [ok]   纳管后 plan → No changes（生成配置与账本天然一致）
......
=====> [moved] 改名A：moved block（HCL 声明式）——地址 legacy→web
        [ok]   moved 后 plan 0 to destroy（只挪账本，不动引擎）
......
=====> [rm] 摘除：state rm——抹账本，不动引擎（最易误解的操作）
......
        [ok]   state rm 后 state list 无 docker_container.temp（账本已抹）
        [ok]   容器 tf10-temp 还活着（摘除 ≠ 删除！）
        [ok]   plan 竟要'重新创建'它（1 to add）——对不认识的资源这就是名字冲突危险面
......
=====> [verify] 终态断言：账实一致 + backup 链在
......
        断言汇总：PASS=17 FAIL=0
```

分步跑也行（每步可单独执行）：

- `up`：手工 `docker run` 一台存量容器（此刻 Terraform 不认识它）
- `import`：import block 纳管 + 配置生成 + 收敛断言
- `moved`：moved block 改名（0 destroy 断言）
- `statemv`：state mv 改名对照（镜像地址，殊途同归验证）
- `rm`：state rm 摘除 + 名字冲突危险面断言
- `verify` / `clean`：终态断言（账实一致、backup 链在）/ 零残留

诚实预期：本实验用本地 state（无锁），必须单人顺序操作；`up` 建的存量容器在 `clean` 的 destroy 里会被真删——纳管即接管，接管即负责。

## How It Works

纳管的收敛钥匙是配置生成。`terraform plan -generate-config-out=generated.tf` 会照账本实况把资源体完整写出（含引擎回读的全部属性），随后 apply 执行登记。

生成配置与 state 天然一致，所以纳管后的 plan 直接 `No changes`——你在输出里看到的三连（1 to import → generated.tf → No changes）就是这条链。

改名的两条等价路。moved block 写进配置：`moved { from = ... to = ... }`，plan 显示 0 to destroy——Terraform 按声明把旧地址的 state 记录改贴到新地址，引擎里的容器一行命令都没执行。

state mv 是同一件事的命令式版本：先同步改配置里的资源地址，再 `terraform state mv 旧地址 新地址`。脚本里容器走 moved、镜像走 state mv，两个 plan 都收敛，验证了等价性。

摘除的语义要特别强调：state rm 只删账本记录。引擎里的容器原地不动（断言：容器还活着），但下一次 plan 会把它当作"待新建"——计划里出现 1 to add，apply 就会因同名容器冲突而失败。这个危险面是本实验最重要的输出。

本地 state 的 backup 链：每次 state 变动（import、moved、mv、rm）Terraform 都自动把变更前的账本存为 terraform.tfstate.backup。verify 断言了这个文件的存在——误操作后的第一恢复手段永远是这份自动留底。

## Pitfalls & Q&A

- **kreuzwerker 的 importer 只认完整 64 位容器 ID**：容器名与截断 ID（12 位短格式）都会报 `Cannot import non-existent remote object`，即使容器明明在跑。解法：`docker inspect --format '{{.Id}}'` 取完整 ID 动态填入 import 声明（脚本已封装）。
- **HCL（HashiCorp 配置语言，Terraform 配置文件的语法）标签替换要用引号形式**：资源地址在配置里的写法是 `"docker_container" "legacy"`（引号+空格），`docker_container.legacy` 点号形式只出现在 moved 块与 state 命令里。
- **点号误替换的后果**：用点号做 sed 会把 moved 块改成 `from = web` / `to = web` 的自相矛盾，报 "resource is still declared"。
- **`-generate-config-out` 是 plan 专用旗标**：apply 不认识它，报 `flag provided but not defined`。解法：plan 时生成，apply 只需普通参数（generated.tf 已在工作目录里生效）。
- **断言脚本里 `|| true` 会吃掉失败证据**：`grep -q ... || true` 后接 `assert $?` 会让断言永远通过（rc 被 true 覆盖）。解法：探测结果存变量（`ok=0`/`ok=1`），断言断变量而不是断 `$?`。

Q：import 之后还能改这份资源配置吗？A：能，纳管完成后它就是普通受管资源，后续变更走正常 plan/apply；generated.tf 也可以按需精简（改完后 plan 验证仍 No changes 即可）。

Q：state rm 的正确用途是什么？A：确认实体已无主（或已手工删除）时的账务清理，以及把资源移交其他管理面（先 rm 再由新管理者 import）。绝不能用它"假装没看见"一个还在服务的资源——账外孤儿正是本实验演示的危险面。
