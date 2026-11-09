# 🎯 Terraform 面试 22 小项目学习清单 · Todo List（TA-003 考纲打底 + 高频实战题 · 本机零云）

> 通过 22 个小项目（每项目 100-300 行 HCL/脚本）钉死面试考点：工作流与 DAG → HCL 表达式 → state 深水区（锁/漂移/事故）→ 模块与多环境 → Provider/CI/OpenTofu 生态
> 约束：本机 macOS + OrbStack(Docker) 全跑通、**零云依赖**、全部免费；对象存储用自家 ObjStor（Rust S3 兼容存储，lab 03 同款），AWS 语义考点用 LocalStack 模拟（**不用 MinIO**），部署目标 Docker/kind/本机 postgres
> 串联机制：考点驱动型——每项目头部「覆盖考题」引用高频考法，开头给考点→项目速查表；项目 22 🏁 综合事故演练收口
> 前置：devops.md 项目 1-5（✅ 已完成：provider 入门/模块入门/state 概念/workspace vs 目录）——本清单**只钉考点不重复教学**（关系见文末）
> 预计周期：8 周（每天 1-2 小时）

## 🗺️ 考点→项目速查表

### TA-003 认证九大考纲域

| 考纲域 | 对应项目 |
|:---|:---|
| 1. IaC 概念（幂等/不可变/声明式） | 1、20 |
| 2. Terraform 的目的（vs 手工/脚本/其他工具） | 1、21（对照 pulumi 思想） |
| 3. Terraform 基础（init/plan/apply/state 概念） | 1、7 |
| 4. 模块交互（source/version/结构） | 13 |
| 5. 工作流导航（验证/预演/执行） | 1、2、16 |
| 6. 实施与维护 state（remote/lock/sensitive） | 7-12（深水区） |
| 7. 读改生成配置（资源语法/meta-args） | 4、5 |
| 8. 管理 resource state（import/moved/drift） | 10、11、12 |
| 9. 其他 HCL 特性（表达式/函数/动态块） | 3、6 |

### 高频实战面试题

| 高频题 | 对应项目 |
|:---|:---|
| 「tfvars/-var/环境变量优先级」 | 2 |
| 「count 和 for_each 怎么选」 | 4 |
| 「create_before_destroy/prevent_destroy/ignore_changes」 | 5 |
| 「state lock 是什么？锁死了怎么办？」 | 8、9 |
| 「S3 backend 为什么需要 DynamoDB」 | 9 |
| 「存量资源怎么纳管/import 怎么用」 | 10 |
| 「什么是漂移？怎么检测和修复？」 | 11 |
| 「state 丢了/损坏了怎么办？state 里的明文密钥？」 | 12 |
| 「state 太大怎么拆？模块间怎么解耦？」 | 14 |
| 「多环境怎么管？workspace vs 目录 vs Terragrunt」 | 15 |
| 「IaC 怎么保证质量？policy as code？」 | 16、17 |
| 「Terraform 怎么进 CI/CD？Atlantis 是什么？」 | 17 |
| 「OpenTofu 和 Terraform 什么关系？」 | 21 |
| 「provisioner 是反模式吗？」 | 20 |
| 「线上 state 损坏 + 并发 + 漂移，你的处置流程？」 | 22 🏁 |

## 🤖 AI 辅助提示词速查

| 场景 | 提示词 |
|:---|:---|
| **开始一个新项目** | `我要开始 Terraform 面试项目「[名称]」，钉死考点：[考点]。请给我完整 HCL/脚本约 [行数] 行，macOS + Docker 本机可跑、零云，含可执行验收断言。只输出代码。` |
| **排障** | `我的 Terraform 配置出现 [现象]，报错/plan 输出：[粘贴]。请分析根因并给修复后的完整配置。` |
| **写验收脚本** | `请为「[项目名]」写验收脚本：对产出逐条断言（参考清单验收标准），失败输出实际差异，全过打印 [ok]。` |
| **模拟面试官追问** | `我是 Terraform 面试官。针对「[考点]」连续追问 5 层，从概念到生产事故场景，我答一层你追问一层。` |

## 📊 总进度

进度：██░░░░░░░░░░░░░░░░░░ 3/22 (14%)

| 阶段 | 项目数 | 已完成 |
|:---|:---:|:---:|
| 第一阶段：考纲地基——工作流与 HCL | 6 | 0 |
| 第二阶段：state 深水区 | 6 | 3 |
| 第三阶段：模块与工程化 | 5 | 0 |
| 第四阶段：生态与进阶考点 | 5 | 0 |
| **合计** | **22** | **3** |

---

## 🗂️ 第一阶段：考纲地基——工作流与 HCL（项目 1-6）

> **目标**：考纲 3/5/7/9 域稳过——每个语法点都能带出一段生产故事

### [ ] 项目 1：工作流深潜——init/plan/apply 生命周期与 DAG 依赖图

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | 生命周期三段、执行计划 `-out`、plan JSON 机读、DAG 依赖图、隐式/显式依赖 |
| **覆盖考题** | 「plan 和 apply 的区别？为什么要先 plan？」「Terraform 怎么决定资源创建顺序？」「init 到底做了什么？」「-target 危险在哪？」（-target 在项目 14 深挖） |
| **前置** | devops.md 项目 1 |
| **验收标准** | 打乱 .tf 文件内 resource 书写顺序两次 apply，第二次均输出 `No changes`（幂等断言），且 graph 输出含显式 `depends_on` 边 |
|  | `terraform plan -out` + `terraform show -json` 用 jq 断言 `resource_changes` 数量与容器数一致 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「工作流深潜与 DAG」。请给我完整 HCL+脚本约 150 行：docker provider 起一组有依赖的容器（网络→存储→应用），乱序书写验证自动排序，plan -out + show -json 机读断言，terraform graph 渲染依赖图并验证 depends_on 边存在，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 2：变量工程——类型/validation/sensitive/优先级实测

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | variable 声明与验证、sensitive 标记、值来源六通道、优先级实测 |
| **覆盖考题** | 「-var、-var-file、*.auto.tfvars、terraform.tfvars、TF_VAR_ 环境变量，谁覆盖谁？」「如何防止敏感值进日志和 state？」（state 侧在项目 12 收口） |
| **前置** | 项目 1 |
| **验收标准** | 六种来源同时注入同一变量，脚本生成优先级实测表并逐行断言（顺序：默认 < tfvars < auto.tfvars < -var/-var-file） |
|  | validation 拒绝非法值 exit≠0 且报错含 "Invalid value"；sensitive 输出在 `terraform output -json` 中 value=null |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「变量工程与优先级」。请给我完整 HCL+脚本约 180 行：带类型与 validation 的变量、六种值来源注入脚本、优先级实测对照表生成与断言、sensitive 输出掩码行为验证，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 3：表达式与函数深水区——console 调试 15 题

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | for 表达式、字符串模板 %{if/%{for} 指令、splat、try/can、函数族（lookup/merge/coalesce/join/split/format/tomap/toset） |
| **覆盖考题** | 「for 表达式和 for_each 的区别」「terraform console 怎么调试？」「try 和 can 的区别？」 |
| **前置** | 项目 2 |
| **验收标准** | 15 道 console 表达式题判分脚本全过（含 1 道 try 兜底题、1 道 can 分支题） |
|  | 字符串模板渲染产物（含 %{if} 指令）与 golden file 逐字一致 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「表达式与函数深水区」。请给我完整内容约 180 行：15 道 terraform console 表达式题（函数族/for 表达式/splat/try/can）、带 %{if} 指令的模板渲染 + golden file、console 判分脚本（echo 进 console 断言输出）。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 4：count vs for_each——重构灾难复现

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | count 索引寻址、for_each 键寻址、索引漂移灾难、安全迁移（moved/state mv） |
| **覆盖考题** | 「为什么生产推荐 for_each？」「count 的列表中间插入一个元素会怎样？」「怎么从 count 安全迁到 for_each？」 |
| **前置** | 项目 1 |
| **验收标准** | 3 容器 count 部署后，在列表中间插入元素：plan 断言出现 ≥2 个 destroy+create（灾难复现）；用 moved block 迁到 for_each 后再插入：plan 仅 +1 create、0 destroy |
|  | for_each 键集合用 `toset`/`tomap` 构造，键序变化不影响资源身份（二次 plan `No changes` 断言） |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「count vs for_each 重构灾难」。请给我完整 HCL+脚本约 180 行：count 三容器部署、列表中间插入的灾难 plan 复现、moved block 迁移到 for_each、迁移后再插入仅新增的对照验证，附逐条验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 5：元参数与 lifecycle——三种保护实测

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | depends_on/lifecycle：create_before_destroy、prevent_destroy、ignore_changes |
| **覆盖考题** | 「create_before_destroy 什么场景必须用？」「prevent_destroy 防的是什么（它防得住 state rm 吗？）」「标签被外部系统改了导致循环替换，怎么容忍？」 |
| **前置** | 项目 1 |
| **验收标准** | prevent_destroy 下 `terraform destroy` exit≠0 且报错含 "this resource is set to be destroyed"?——以实际文案断言（阻止删除）；加 create_before_destroy 后改名场景 plan 显示先 create 后 destroy（顺序断言） |
|  | 手工改容器标签后 ignore_changes 使 plan 回到 `No changes`（0 diff 断言）；去掉后 plan 检出 diff（对照） |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「lifecycle 三种保护」。请给我完整 HCL+脚本约 150 行：docker 容器三种 lifecycle 配置（prevent_destroy 阻断 destroy、create_before_destroy 改名替换顺序、ignore_changes 容忍带外标签修改），每种一条 plan/apply 断言脚本与实际报错文案捕获。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 6：检查块——precondition/postcondition/验证链

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | variable validation、lifecycle precondition/postcondition、检查时机差异、terraform test 初见 |
| **覆盖考题** | 「precondition 和 postcondition 区别？各自在什么阶段评估？」「data source 的 postcondition 用来干什么？」「validation 能引用其他变量吗？」 |
| **前置** | 项目 2、5 |
| **验收标准** | 三层拦截各有断言：非法变量被 validation 拒（apply 前拦截）；precondition 在资源创建前评估（失败时容器未创建——`docker ps` 断言不存在）；postcondition 失败时 apply 中止且报错含 "Resource postcondition failed" |
|  | `terraform test` 用例 ≥2 个覆盖 condition 路径（1.6+ 测试框架初见，项目 16 深挖） |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「检查块与条件链」。请给我完整 HCL+脚本约 180 行：variable validation + lifecycle precondition（镜像架构校验，失败时断言容器未创建）+ postcondition（失败报错文案捕获）三层拦截、terraform test 两个用例，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第二阶段：state 深水区（项目 7-12）

> **目标**：面试最高频考点全实操——state 的锁、漂移、事故、敏感面都亲手摸过

### [ ] 项目 7：state 解剖——serial/lineage/backup 链

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | tfstate JSON 结构、serial/lineage 语义、.tfstate.backup 链、state 与真实资源的映射 |
| **覆盖考题** | 「state 文件里有什么？」「serial 和 lineage 干什么用的？」「terraform show / state list / state pull 的区别？」「state 为什么必须当敏感数据处理？」 |
| **前置** | 项目 1 |
| **验收标准** | jq 提取 state 的 serial/lineage/resources 断言结构；连续两次 apply 后 serial 严格递增（数值断言）；apply 后 `.tfstate.backup` 存在且其 serial = 当前 -1 |
|  | `state list`、`show`、`pull -0` 三种读法输出形态对照表落盘 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「state 解剖」。请给我完整脚本约 150 行：tfstate JSON 结构解析（serial/lineage/资源映射）、连续 apply 的 serial 递增断言、backup 链验证、state list/show/pull 三种读法对照表生成。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 8：远程 backend 与真锁——PostgreSQL backend 并发竞争

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | terraform_remote_state 配置、pg backend、状态锁、force-unlock 及其危险性 |
| **覆盖考题** | 「state lock 是什么？为什么需要？」「两个人同时 apply 会发生什么？」「锁卡死（持有者崩溃）怎么处理？force-unlock 有什么风险？」 |
| **前置** | 项目 7；本机 postgres:16-alpine 镜像（已有） |
| **验收标准** | 终端 A 长时间 apply 期间终端 B apply：exit≠0 且报错含 "Error acquiring the state lock"（并发竞争复现）；pg_locks 表 advisory 锁当场可见 |
|  | SIGSTOP 假死滞留复现 + 真解 pg_terminate_backend 掐连接恢复 apply（force-unlock 在 pg 后端的真实行为如实记录：报成功但锁不动）|

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「pg backend 真锁并发」。请给我完整 HCL+脚本约 200 行：本机 postgres 容器 + pg backend 配置、双终端并发 apply 竞争锁复现（锁报错捕获）、持锁者死亡模拟与 force-unlock 恢复、风险说明。附验收命令。只输出代码。`

**完成日期**：2026-11-08
**踩坑记录**：初版带 docker_container 撞上 OrbStack 引擎 log_opts 注入 → ForceNew 永久替换不收敛，改 docker_image+time_sleep 才收敛；force-unlock 在 pg 后端**假成功**（真解是 pg_terminate_backend）；杀 CLI 留 provider"诈尸"完成半途 apply（kill 必须连子进程）。完整复盘见 terraform/08_pg_backend_lock/README.md 的 Pitfalls

---

### [x] 项目 9：S3 backend 与锁机制——ObjStor 真锁 + DynamoDB 理论对照

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~220 行 |
| **核心知识点** | S3 backend 字段、use_lockfile（TF≥1.10 原生 S3 锁）、ObjStor 宿主进程 S3 后端、dynamodb_table 传统锁理论 |
| **覆盖考题** | 「S3 backend 为什么需要 DynamoDB？」「TF 1.10 的 S3 原生锁是什么（use_lockfile）？」「S3 backend 必配哪些字段？」「为什么 state 不放 git？」 |
| **前置** | 项目 8；ObjStor（自家 Rust S3 兼容存储，lab 03 已验证，启动模式**参考 labs/03_tf_state/tf_state.sh backend 段**） |
| **⚠️ 风险** | ObjStor 从进程 CWD 读硬编码相对路径 `data/config/objstor.json`——必须 cd 进专属目录启动（lab 03 已踩平）；dynamodb_table 传统锁对照依赖 LocalStack（拉取中），fallback 理论化 + 项目 8 pg 真锁补实操 |
| **验收标准** | ObjStor（S3 API :9200，凭据 minioadmin）上以 `use_lockfile = true` 配置 S3 backend，并发 apply 被锁拦截（报错含 "Error acquiring the state lock"）；bucket/lock 对象在 ObjStor API 可见 |
|  | 重启 ObjStor 进程后 `terraform plan` 从远端读到完整 state（远程性断言）；DynamoDB 传统锁与 use_lockfile 的演进对照表落盘（LocalStack 可选实操） |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「S3 backend 锁机制」。请给我完整 HCL+脚本约 220 行：按 labs/03_tf_state 的模式启动 ObjStor（S3 API :9200 + minioadmin 凭据，注意 CWD 硬编码坑）、S3 backend use_lockfile=true 真锁配置、并发 apply 锁拦截断言、重启远程性验证、DynamoDB 传统锁 vs use_lockfile 演进对照表。附验收命令。只输出代码。`

**完成日期**：2026-11-08
**踩坑记录**：三个新坑入册——versions.tf 漏 required_providers 会去查不存在的 hashicorp/docker；重启脚本复用"全新启动"函数把要证明未丢的数据目录亲手删了（拆 prepare/launch 两段）；plan 崩溃同样留滞留锁（verify 按剧本自愈：取 Lock ID → force-unlock → 重试）。与 08 的核心对照：SIGKILL 后 S3 锁滞留（pg 自动回收）、force-unlock 在 S3 系是真解（pg 假成功）。完整复盘见 terraform/09_s3_backend_lock/README.md 的 Pitfalls

---

### [x] 项目 10：state 操作全家桶——import block/state mv/state rm/moved

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | import block（1.5+）、state mv、state rm、moved block、配置生成 |
| **覆盖考题** | 「存量资源怎么纳管？」「terraform import 和 import block 区别？」「资源改名但不想重建怎么做？」「moved block 和 state mv 什么关系？」 |
| **前置** | 项目 7 |
| **验收标准** | 手工 docker run 的"存量"容器经 import block 纳管后 `terraform plan` 输出 `No changes`（逐字断言）；moved block 重命名后 plan 0 destroy（身份保留断言） |
|  | `state rm` 摘除后 apply 不触碰该容器（容器存活 + state 中条目消失双断言）；import block 与命令行 import 的差异结论落盘 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「state 操作全家桶」。请给我完整 HCL+脚本约 200 行：手工容器 import block 纳管（plan No changes 断言）、moved block 重命名、state mv 对照、state rm 摘除存活验证、import block vs 命令行 import 差异结论。附验收命令。只输出代码。`

**完成日期**：2026-11-08
**踩坑记录**：四个坑入册——kreuzwerker importer 只认完整 64 位容器 ID（名字/12 位截断都报 not found）→ 动态取 ID；HCL 标签 sed 要用引号形式 `"docker_container" "legacy"`（点号形式只存在于 moved 块，误替换造出自相矛盾）；`-generate-config-out` 是 plan 专用旗标（apply 不认）；断言脚本 `grep -q || true` 会吃 rc 造成假 PASS → 变量式断言。完整复盘见 terraform/10_state_operations/README.md 的 Pitfalls

---

### [ ] 项目 11：漂移检测与修复闭环

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | drift 定义与分类、refresh-only plan、修复两策略（revert vs adopt）、漂移报告 |
| **覆盖考题** | 「什么是漂移？怎么产生？」「怎么检测漂移？plan 和 refresh-only plan 区别？」「修复漂移的两种策略怎么选？」 |
| **前置** | 项目 5、7 |
| **验收标准** | 手工带外改动（容器标签+文件内容）后 `terraform plan` 检出，diff 项与手工改动一一对应（jq 断言）；`refresh-only plan` 输出 0 changes（只刷新不改动断言） |
|  | revert（apply 拉回）与 adopt（改配置收编）两条路径各走通一次，选择决策表落盘 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「漂移检测与修复」。请给我完整 HCL+脚本约 200 行：带外改动注入器、plan 检出 diff 与手工改动对拍、refresh-only plan 零改动断言、revert/adopt 双路径实操与决策表。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 12：state 事故演练——丢失/损坏/敏感明文

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~220 行 |
| **核心知识点** | backup 恢复流程、state 加密（TF 1.10+）、ephemeral 值、state 敏感面治理 |
| **覆盖考题** | 「state 丢了怎么办？」「state 损坏怎么恢复？」「state 里为什么有明文 secret？怎么缓解（加密/ephemeral/外部 secret 管理）？」「多人协作怎么避免 state 被踩？」 |
| **前置** | 项目 8、11 |
| **验收标准** | 事故一（误删 state）与事故二（JSON 损坏）各自从 backup 恢复：恢复后 plan `No changes` 且 serial 连续（断言）；全程容器不受影响（存活断言） |
|  | state 中 grep 到敏感值明文（命中演示）→ 配置 state 加密后重扫未命中（缓解断言），缓解手段分层结论落盘 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「state 事故演练」。请给我完整脚本约 220 行：state 误删与 JSON 损坏两场事故的恢复流程（serial 连续断言）、state 明文敏感值检索演示、TF 1.10 state 加密启用前后对照、缓解手段分层结论表。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第三阶段：模块与工程化（项目 13-17）

> **目标**：从"会写 TF"到"会在团队里用 TF"——模块、拆分、多环境、门禁都有实战话语权

### [ ] 项目 13：模块设计与私有 registry

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心知识点** | 模块接口（输入/输出约定）、source 形态与版本锁定、私有 module registry（git tag）、跨模块取值链 |
| **覆盖考题** | 「module 的 source 支持哪些形态？」「模块版本怎么锁定？升级怎么走？」「monorepo 里的模块怎么共享？」「深层资源的属性怎么暴露出来？」 |
| **前置** | devops.md 项目 2 |
| **验收标准** | docker 网络+容器打包成模块，推到本机 gitea git repo 并打 tag，`source = "git::...//module?ref=v1.0.0"` 引用生效（init 下载日志含 ref 断言） |
|  | v1.0.0→v1.0.1 升级走通（.terraform/modules 缓存更新断言）；三层取值链（资源 attr→模块 output→根引用）值正确 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「模块设计与私有 registry」。请给我完整 HCL+脚本约 250 行：docker 网络+容器模块（README/示例/版本 tag）、推本机 gitea、ref 版本引用与升级流程、三层取值链验证。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 14：大 state 拆分与跨层引用——-target 的危险

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~220 行 |
| **核心知识点** | state 拆分策略、terraform_remote_state data source、层间解耦、-target 局部性风险 |
| **覆盖考题** | 「state 太大有什么问题？怎么拆？」「拆完的层之间怎么引用？」「-target 为什么危险（生产几乎禁用）？」 |
| **前置** | 项目 9、13 |
| **验收标准** | 单 state 十资源拆成 network/app 两层：app 层经 `data.terraform_remote_state` 读到 network 层输出值（值断言）；两层各自 plan `No changes` |
|  | -target 局部 plan 的变更集小于全量（数量断言）且其计划缺依赖项的风险场景演示落盘 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「state 拆分与跨层引用」。请给我完整 HCL+脚本约 220 行：十资源单 state 拆两层、remote_state data source 跨层引用、-target 局部 apply 与风险演示、拆分前后 plan 时间对比。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 15：多环境策略横评——workspace vs 目录法 vs Terragrunt 思想

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心知识点** | workspace 状态隔离、目录法复用边界、Terragrunt 核心机制（复刻 generate/每环境 state 映射）、选型五维 |
| **覆盖考题** | 「workspace 和目录法怎么选？」「workspace 的 state 物理在哪？」「terragrunt 解决什么问题？不引入它怎么复刻核心收益？」 |
| **前置** | devops.md 项目 4 |
| **验收标准** | 同一配置三形态落地（workspace dev/staging、目录法、手写 Terragrunt 式根配置生成），各自起容器成功且 state 物理路径互不相同（隔离断言） |
|  | 五维选型对照表落盘（state 隔离/代码复用/diff 可见性/漂移影响半径/工具复杂度） |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「多环境策略横评」。请给我完整 HCL+脚本约 250 行：workspace 与目录法与手写 Terragrunt 核心机制（根配置 generate + 每环境 state 映射）三形态落地、state 物理隔离路径断言、五维选型对照表生成。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 16：测试与静态门禁——terraform test/tflint/trivy/conftest

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心知识点** | terraform test 框架（.tftest.hcl）、tflint 规则集、trivy config 扫描、conftest/OPA 对 plan JSON |
| **覆盖考题** | 「terraform test 框架怎么用？测什么不测什么？」「IaC 静态检查工具链怎么选？」「policy as code 在 IaC 的落点在哪（plan 之前还是之后）？」 |
| **前置** | 项目 1、6；tflint 0.58/trivy 0.74/conftest 已装（✅ 实测） |
| **验收标准** | .tftest.hcl 用例 ≥3 个全过（含 apply 阶段断言）；三种工具各自注入违规样本被拦截 exit≠0，3/3 |
|  | conftest 自写 2 条 policy（禁 latest 标签/必须 env 标签）对 plan JSON 生效（违规 plan 被拒断言）；一键门禁组合脚本产出 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「测试与静态门禁」。请给我完整内容约 250 行：.tftest.hcl 三个用例、tflint 配置与违规样本拦截、trivy config 扫描、conftest 两条 policy 对 plan JSON、一键门禁组合脚本。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 17：PR 门禁流水线——plan artifact 与人工审批

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~280 行 |
| **核心知识点** | PR plan 门禁、plan 文件 artifact 传递与一致性（stale plan 拦截）、人工审批、apply 权限治理、Atlantis/TFC 概念对照 |
| **覆盖考题** | 「Terraform 怎么进 CI/CD？」「为什么 CI 里要保存 plan 文件再 apply？」「Atlantis/Terraform Cloud 解决什么？」「apply 权限怎么收敛？」 |
| **前置** | 项目 16；本机 gitea 容器（✅ 运行中） |
| **验收标准** | gitea actions 全链路：PR 触发 fmt/check/tflint/conftest/plan→plan 文件上传 artifact→手动审批→apply 复用同一 plan 文件（成功断言） |
|  | 生成 plan 后改动配置再用旧 plan apply：被 stale 拦截（exit≠0 且报错含 "Saved Terraform plan is stale" 断言） |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「PR 门禁流水线」。请给我完整 workflow 约 280 行：gitea actions 五道检查+plan artifact 上传+environment 审批+apply 复用 plan 文件、stale plan 拦截演示、Atlantis/TFC 概念对照结论。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第四阶段：生态与进阶考点（项目 18-22）

> **目标**：生态观点 + 综合场景——面试官问到"你们怎么做 X"时每个点都有亲历故事

### [ ] 项目 18：Provider 工程——多别名/lock 文件/离线 mirror

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | required_providers 版本约束（~> 语义）、.terraform.lock.hcl、provider alias 多实例、filesystem mirror 离线 init |
| **覆盖考题** | 「.terraform.lock.hcl 干什么？要不要提交到 git？」「~> 1.2 什么含义？」「provider 多实例（alias）什么场景用？」「离线/弱网环境怎么 init？」 |
| **前置** | 项目 1 |
| **验收标准** | 双 alias 的 docker provider（不同 DOCKER_HOST）各起一容器（隔离断言）；版本约束 `~>` 边界行为实测（超约束版本被拒断言） |
|  | 删 lock 文件重 init 重新生成且 hash 一致（对比断言）；filesystem mirror 断网 init 成功（离线断言） |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「Provider 工程」。请给我完整 HCL+脚本约 200 行：双 alias provider 多实例、~> 版本约束边界实测、lock 文件删除重生成 hash 对比、filesystem mirror 离线 init 演示。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 19：LocalStack AWS provider 实战——endpoint 覆盖与凭据链

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | aws provider endpoint/skip_* 配置、凭据链（env/static/shared/config）、S3/IAM 基础资源 |
| **覆盖考题** | 「provider 怎么指向自定义 endpoint？」「AWS 凭据链按什么顺序解析？零云环境怎么绕？」「为什么 TFC/TTN 环境推荐 OIDC 短时凭据？」 |
| **前置** | 项目 9 |
| **⚠️ 风险** | 依赖 LocalStack 可用（同项目 9 探活）；fallback：k8s provider 打本机 kind 走同样的 endpoint/凭据考点（学习目标不变） |
| **验收标准** | S3 bucket + 对象 + IAM user 三资源 apply 成功，且 aws cli（指向 LocalStack）可见同资源（对拍断言） |
|  | 凭据链三种方式（env/static/shared file）各 init 成功一次；故意配错凭据得到明确报错（文案断言） |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「LocalStack AWS provider」。请给我完整 HCL+脚本约 200 行：aws provider endpoint/skip 配置、S3+IAM 三资源、凭据链三方式对照、错误凭据报错捕获、aws cli 对拍。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 20：provisioner 反模式与逃生舱

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | local-exec/remote-exec 边界、provisioner 盲区（漂移不可见）、null_resource + triggers、镜像内置配置对照 |
| **覆盖考题** | 「为什么说 provisioner 是 last resort？」「provisioner 的改动 plan 能看见吗？」「null_resource 的 triggers 干什么？」「配置进镜像 vs 运行期打补丁怎么选？」 |
| **前置** | devops.md 项目 12（Packer 思想）、项目 11（漂移） |
| **验收标准** | provisioner 改容器内文件后 `terraform plan` 输出 `No changes`（盲区断言——看不见的改动正是反模式论据，结论落盘）；手工删掉该文件后 TF 依然无感（对照断言） |
|  | null_resource + triggers 变更触发重建联动（recreate 断言）；"provisioner vs 镜像内置"三场景选型表落盘 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「provisioner 反模式」。请给我完整 HCL+脚本约 180 行：local-exec 改容器文件的盲区断言（plan 无感）、null_resource+triggers 重建联动、与镜像内置配置（复用 Packer 思想）三场景选型表。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 21：OpenTofu 对照实验——分叉、兼容与 registry 镜像

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | BSL vs MPL 分叉背景、tofu 兼容性、state 双工具互读、network_mirror（TF 已移除该能力的争议） |
| **覆盖考题** | 「OpenTofu 和 Terraform 什么关系？为什么分叉？」「BSL 许可证争议是什么？」「你们怎么选型？怎么避免 lock-in？」 |
| **前置** | 项目 18 |
| **⚠️ 风险** | tofu 待装（brew install opentofu）；network_mirror 指向公共镜像源的可达性不确定——探活，fallback 自建 filesystem mirror 演示同等机制 |
| **验收标准** | 同一 docker 配置 terraform 与 tofu 各 apply 成功，产物等价（容器标签断言）；同一 state 文件双工具 `show` 解析一致（JSON diff 为空断言） |
|  | tofu network_mirror 配置生效（mirror 下载 provider 断言）；「TF 移除 mirror 支持 vs tofu 支持」结论落盘 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「OpenTofu 对照实验」。请给我完整 HCL+脚本约 180 行：同配置双工具 apply 对照、state 双工具互读 JSON diff 断言、tofu network_mirror 配置与生效验证、分叉背景与选型结论表。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 🏁 项目 22：终极串联——事故处置全流程白板演练

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~300 行 |
| **核心知识点** | 复合事故编排（state 损坏+带外漂移+模拟并发）、处置 runbook、面试白板卡 |
| **覆盖考题** | 综合场景：「线上 state 损坏 + 团队正在并发操作 + 存在带外漂移，给出你的完整处置流程」「从 0 到 1 给团队设计 Terraform 工作流与治理」 |
| **前置** | 项目 1-21 |
| **验收标准** | 一条脚本注入复合事故→按 runbook 处置（全员冻结→备份恢复→锁检查→漂移修复→import 对账→测试→门禁→发布）≤10 分钟全通，每步断言 |
|  | 终态 plan `No changes` + 全容器期望状态；生成「面试白板卡」md：处置流程图 + 22 项目考点索引，可打印带进面试 |

**🤖 开始提示词**：
> `我要开始 Terraform 面试项目「终极串联：事故处置演练」。请给我完整脚本约 300 行：复合事故注入（state 损坏+漂移+并发模拟）、runbook 八步处置全断言、面试白板卡 md 生成（流程图+考点索引）。附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 📅 周计划

| 周次 | 内容 | 项目数 |
|:---|:---|:---:|
| **第 1 周** | 项目 1-3（工作流/DAG + 变量优先级 + 表达式函数） | 3 |
| **第 2 周** | 项目 4-6（count/for_each + lifecycle + 检查块） | 3 |
| **第 3 周** | 项目 7-9（state 解剖 + pg 真锁 + S3/DDB backend） | 3 |
| **第 4 周** | 项目 10-12（state 全家桶 + 漂移 + 事故演练） | 3 |
| **第 5 周** | 项目 13-15（模块 registry + state 拆分 + 多环境横评） | 3 |
| **第 6 周** | 项目 16-18（测试门禁 + PR 流水线 + Provider 工程） | 3 |
| **第 7 周** | 项目 19-21（LocalStack AWS + provisioner + OpenTofu） | 3 |
| **第 8 周** | 项目 22 🏁 + 全考点复盘（速查表逐条自测） | 1 |

## 🏆 里程碑

- [ ] **完成项目 1-6** → 🧱 「工作流与 HCL 熟手」：考纲 3/5/7/9 域稳过，每个语法点能带出一段实测故事
- [ ] **完成项目 7-12** → 🔐 「state 深水区生存者」：锁/漂移/事故/敏感面全亲手摸过——面试最高频区拿下
- [ ] **完成项目 13-17** → 🏗️ 「团队工程化选手」：模块/拆分/多环境/门禁有实战话语权
- [ ] **完成项目 18-22** → 🎯 「面试通关」：生态观点成型，综合场景白板可画

## 🔧 环境配置

```bash
# 0. 已就绪（2026-11-08 实测核验）
#    terraform v1.15.8 / tflint 0.58.0（含 terraform ruleset）/ trivy 0.74.0 / conftest
#    jq / yq / python 3.13 / kind 0.32 / kubectl 1.33
#    gitea:1.22 容器运行中（项目 13/17 载体）；postgres:16-alpine 镜像在库（项目 8）
#    ObjStor（自家 Rust S3 兼容存储）：源码在仓库同级 ../objstor，lab 03 已验证跑通
#    TF S3 backend；宿主进程模式跑 S3 API :9200，启动/配置/凭据模式参考
#    labs/03_tf_state/tf_state.sh backend 段（⚠️ CWD 硬编码 data/config/objstor.json，
#    必须 cd 进专属目录启动；首次需 cargo build --release，约 1 分钟）
#    registry.terraform.io：labs 01-05 已验证可下载 provider
#    ⚠️ 不引入 MinIO（经常出问题）——S3 兼容存储统一用 ObjStor，AWS 全语义模拟用 LocalStack

# 1. 需安装
brew install opentofu          # tofu（项目 21）；terragrunt 不装，项目 15 手写复刻其思想

# 2. 需拉取
docker pull localstack/localstack   # 仅项目 9 选做（DynamoDB 锁对照）+ 项目 19（AWS provider）
#                                    # （拉取中，mirror 偶发 EOF 重试即可）

# 3. 每项目开工前统一检查
terraform version && docker info > /dev/null && echo "[ok] 就绪"
```

## ⚠️ 与已有清单的关系

| 已有清单/实验 | 关系 |
|:---|:---|
| devops.md 项目 1-5（labs 01-05：provider/模块/state/workspace 入门） | 入门教学**不重复**——本清单对应项目是考点深度重构：项目 13 的私有 registry 是 lab 02 没做的 git tag 版本化；项目 8-12 的远程锁/漂移/事故是 lab 03 概念之上的实操深水 |
| devops.md 项目 3（labs 03：state 深潜，含 ObjStor 后端回退方案） | 项目 9 直接复用 lab 03 的 ObjStor 启动模式（宿主进程 S3 API :9200 + CWD 坑已踩平），考点升级到 use_lockfile 真锁与锁演进对照；MinIO 在 lab 03 是首选、在本清单**被排除** |
| devops.md 项目 12（labs 12：Packer 流水线） | 项目 20 的"配置进镜像 vs provisioner"对照复用其思想，不重复教学 |
| pulumi.md（12/12 完成） | 项目 7 state 解剖时对照 Pulumi state 模型是面试加分观点；不重复 IaC 概念 |
| cicd.md / cicd-semi.md | 项目 17 的 gitea 载体复用，CI 平台本身不教；plan 门禁思想与 cicd.md 项目 6 审批流互补 |
| devsecops.md 项目 16/21（门禁） | 门禁思想同源：那边是安全策略，本项目 16/17 是 TF 质量门禁（tflint/conftest 工具重叠属有意复用） |

## 📚 能力覆盖速查表（2026-11-08 实测）

| 能力/工具 | 计划 | 实测结论 |
|:---|:---|:---|
| terraform v1.15.8 | 全清单主线 | ✅ 已装（labs 01-05 验证 provider 下载可达） |
| tflint 0.58.0 + ruleset | 项目 16/17 门禁 | ✅ 已装 |
| trivy 0.74 / conftest | 项目 16 policy 扫描 | ✅ 已装（devsecops 清单同款复用） |
| postgres:16-alpine | pg backend 真锁（项目 8） | ✅ 镜像在库 |
| ObjStor（自家 Rust S3 兼容存储） | S3 backend 真锁（项目 9） | ✅ lab 03 已验证（宿主进程 S3 API :9200，use_lockfile 可用）；启动模式参考 labs/03_tf_state/tf_state.sh |
| LocalStack（AWS 全语义模拟） | 项目 9 选做（DynamoDB 对照）+ 项目 19 | ⚠️ 镜像拉取中（mirror 偶发 EOF，重试即可）；开工探活；fallback：项目 19 换 k8s provider 打本机 kind（学习目标不变） |
| OpenTofu（tofu） | 项目 21 | ⚠️ 待装（brew opentofu，无平台障碍） |
| terragrunt | 项目 15 | ❌ 有意不装——手写复刻其核心机制（面试讲得出原理比会用工具更值钱） |
| MinIO | — | ❌ **用户明确排除**（经常出问题）；S3 兼容存储统一用自家 ObjStor（lab 03 同款） |
| registry.terraform.io | provider 下载 | ✅ 历史验证可达；若慢复用 .terraform 缓存 |
| Atlantis / TFC/TTN | 概念考点 | 📖 理论对照（项目 17），零云不实操——面试讲清"它替你做了什么"即可 |
| tofu network_mirror 公共源 | 项目 21 | ⚠️ 可达性不确定，探活；fallback 自建 filesystem mirror |

## 📝 每日日志

| 日期 | 项目 | 耗时 | 收获 | 踩坑 |
|:---|:---|:---:|:---|:---|
| | | | | |
