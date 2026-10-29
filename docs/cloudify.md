# ☁️ Cloudify 16 小项目学习清单 · Todo List（TOSCA 编排 · 本地模式先行 · 零云）

> 通过 16 个小项目（每项目 100-250 行 YAML/Python/Bash）学会 Cloudify：TOSCA 建模与本地执行 → 自写插件/工作流 → 把 Docker/Terraform/Ansible/K8s 纳入同一张编排图 → Manager 平台运维 → 蓝图即代码 CI 闭环
> 约束：本机 macOS（Apple Silicon）+ Docker（OrbStack）全跑通、**零云**、全部免费；`cfy` 7.0.5 必须跑在 **Python 3.11 venv**（3.13 实测不兼容）；国内网络：GitHub 文件走 `api.github.com` / `codeload`，镜像走 `docker.1ms.run`
> 串联机制：阶段即能力等级——TOSCA 建模（零 Manager）→ 插件与「编排器之上的编排器」→ Manager 平台能力 → K8s 与交付闭环；项目 9 ⛓️ 首次双工具组合、项目 13 ⛓️ 插件上平台、项目 16 🏁 单蓝图跨四世界
> 预计周期：6 周（每天 2-3 小时）
> 定位：**devops.md / pulumi.md 的互补线**——Terraform（labs/01-04）、Ansible（labs/06）、kind 已学过的东西在这里只当「被编排的载荷」复用，不重讲；全程 TF ↔ Pulumi ↔ Cloudify 三方对照（关系见文末）
> ⚠️ 项目状态（2026-10-26 实测）：核心仓库 cli/manager/common 最后提交 **2024-08**，CLI 最后发版 **2024-11**（7.0.5），六个官方插件最后发版 2024-03~09；Dell 2023 收购后内部包改名 Fusion（`fusion-common` 不公开），仓库未归档但约两年无提交。按「维护停滞的成熟编排器」来学——TOSCA 建模、工作流引擎、服务组合三块思想可迁移（xOpera / ONAP / Crossplane / AWX），**不建议新生产项目选型**

## 🤖 AI 辅助提示词速查

| 场景 | 提示词 |
|:---|:---|
| **开始一个新项目** | `我要开始 Cloudify 项目「[名称]」（cfy 7.0.5 本地模式/Manager，macOS Apple Silicon + Docker OrbStack，零云）。请给我完整蓝图 YAML + 脚本约 [行数] 行（tosca_definitions_version: cloudify_dsl_1_5，types.yaml 走 vendor/ 相对路径 import，不用 Manager 短路径），附验收命令。只输出代码。` |
| **排障** | `我的 Cloudify 蓝图/执行出现 [现象]，cfy 输出/events：[粘贴]。请分析根因并给修复后的完整蓝图。` |
| **三方对照（TF/Pulumi 并读）** | `对照我在 Terraform/Pulumi 里的做法：[粘贴]，给出等价的 Cloudify TOSCA 蓝图写法，并指出三者在依赖推断、状态模型、生命周期钩子、Day-2 操作上的差异。` |
| **插件开发** | `请用 cloudify-common 7.0.5 的 @operation / ctx API 写一个 Cloudify 插件：[功能]。含 plugin.yaml（dsl_1_5 节点类型）、setup.py、pytest（cloudify.mocks.MockCloudifyContext）。只输出代码。` |
| **Manager REST** | `请给出用 curl 调 Cloudify Manager REST API v3.1 完成 [操作] 的命令（admin:admin，带 Tenant 头），并给出等价 cfy 命令。` |

## 📊 总进度

进度：████████████░░░░░░░░ 12/16 (75%)

| 阶段 | 项目数 | 已完成 |
|:---|:---:|:---:|
| 第一阶段：TOSCA 建模与本地执行（零 Manager） | 4 | 4 |
| 第二阶段：插件与「编排器之上的编排器」 | 5 | 5 |
| 第三阶段：Manager 平台能力（AIO 社区版）⚠️ 闸门 | 4 | 0 |
| 第四阶段：Kubernetes 与交付闭环 | 3 | 3 |
| **合计** | **16** | **12** |

---

## 🗂️ 第一阶段：TOSCA 建模与本地执行——零 Manager（项目 1-4）

> **目标**：用 `cfy` 本地模式跑通 install/uninstall 回路，建立 TOSCA 心智模型（节点 / 关系 / 接口 / 生命周期 / 内建函数 / 工作流与容错），与 TF/Pulumi 逐条对照

### [x] 项目 1：第一个蓝图——本地模式、script 插件与 ctx

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~100 行（蓝图 YAML + Bash 脚本 + 环境脚本） |
| **核心知识点** | `cfy init -b` / `executions start install` / `deployments outputs` / `uninstall` 本地回路、`tosca_definitions_version: cloudify_dsl_1_5`、inputs/outputs、script 插件（`implementation: scripts/x.sh`）、脚本里 `ctx logger` / `ctx instance runtime-properties` 命令行、`get_input` / `get_attribute` 内建函数 |
| **技术栈** | cloudify 7.0.5（清华源 ✅）+ Python 3.11 venv（uv ✅）+ `setuptools<81`；types.yaml 经 `api.github.com` Contents API 取回 vendor（✅ 实测 53KB，20 处 `cloudify.nodes.Root`） |
| **⚠️ 风险** | 四个已踩实的坑（2026-10-26 /tmp 全部复现过）：① Python 3.13 跑 `cfy` 报 `No module named 'cgi'`（3.13 移除该模块）→ 必须 3.11 venv；uv venv 默认不带 setuptools → 缺 `pkg_resources`，补 `setuptools<81`；② 短路径 `imports: - cloudify/types/types.yaml` 是 Manager 侧写法，本地报 `Unable to open import url resource:` → vendor 到蓝图目录用相对路径；③ `raw.githubusercontent.com` 不可达，改用 `api.github.com/repos/.../contents/...` + `Accept: application/vnd.github.raw+json`；④ `CFY_WORKDIR` **不能放在蓝图目录内**（init 整目录递归拷贝 → 无限自嵌套 `File name too long`）；蓝图必须声明 `cloudify_dsl_1_5`（7.0.x types.yaml 用了 1_5 才有的 `operation_name` 参数类型，声明 1_4 解析失败） |
| **验收标准** | `install` 后 `cfy deployments outputs -b app` 含脚本写入的 runtime property（如 `hello-from-cloudify-local`）；`uninstall` 后 `cfy node-instances -b app` 零实例；`init + install` 连跑两遍 outputs 一致（幂等）；`cfy blueprints validate` 对故意写错的 node type 报出 `path: node_templates.x.type` |
| **实验目录** | `cloudify/01_local_hello/`（✅ 2026-10-26 `all` 全绿连跑两遍：11 断言——好/坏 validate、install、outputs、uninstall 零活跃实例、幂等 outputs 逐字节一致） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「第一个蓝图」。请给我约 100 行（蓝图 YAML + scripts/create.sh + setup.sh）：cfy 7.0.5 本地模式，tosca_definitions_version: cloudify_dsl_1_5，import vendor/types.yaml 相对路径；一个 cloudify.nodes.Root 节点用 script 插件跑 bash（ctx logger + ctx instance runtime-properties），input greeting、output 读回 runtime property；附 CFY_WORKDIR=/tmp/cfy_wd 下 init/install/outputs/uninstall 验收命令。只输出代码。`

**完成日期**：2026-10-26
**踩坑记录**：① 蓝图 YAML **只接受 ASCII**——描述里写中文/全角符号报 `illegal characters in line: N. Only valid ascii chars are supported`，中文说明全部进 README；② `cfy` 必须 Python 3.11 venv + `setuptools<81`（3.13 报 `No module named 'cgi'`，缺 setuptools 报 `pkg_resources`，启动时 deprecation 警告无害）；③ `CFY_WORKDIR` 放蓝图目录内 → init 整目录递归拷贝无限自嵌套 `File name too long`；④ 短路径 `cloudify/types/types.yaml` 是 Manager 专属，本地必须 vendor 相对路径 import；⑤ 本地 CLI 查询面只有 `deployments outputs` / `executions list`——`node-instances` 报 `Could not find node list`、`nodes/events` 报 manager-only，实例级断言直读存储 `deployments/<id>/node-instances/*.json`（`state: "deleted"` 判零活跃）；⑥ uninstall 后 outputs 仍返回旧值——是 install 时缓存的快照不是活查询；⑦ 交互探命令时 zsh 不拆词（`${=cmd}` 或写进脚本）

---

### [x] 项目 2：节点类型与内建函数——自定义 node_types / data_types / 输入约束

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | `node_types`（`derived_from: cloudify.nodes.Root` + `properties` schema：type/default/required）、`data_types` 复合类型（嵌套 properties）、`inputs.constraints`（`valid_values` / `in_range` / `pattern` / `min_length`）、`get_property`（解析期静态值）vs `get_attribute`（运行期值）差异、`concat` / `string_replace` / `string_upper` 字符串函数、一个 node_type 两套 node_templates 实例 |
| **前置** | 项目 1 |
| **验收标准** | `cfy init -i port=70000` 被 `in_range` 约束拒绝且报错指出 input 名；两个实例共用一个自定义 type，改 type 的 default 后 `init` 重跑，两实例 outputs 同步变化；outputs 同时展示同一键的 `get_property`（旧值）与脚本覆写后的 `get_attribute`（新值）；对照表（HCL variable validation / Pulumi config 类型化 vs TOSCA constraints）写进实验 README |
| **实验目录** | `cloudify/02_types_functions/`（✅ 2026-10-26 `all` 全绿连跑两遍：6 相 19 断言——三约束负向、8 输出逐项、默认演化同步） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「节点类型与内建函数」。请给我约 120 行蓝图：自定义 node_types + data_types，inputs 带全约束集（valid_values/in_range/pattern/min_length），演示 get_property vs get_attribute 差异（脚本运行时覆写 runtime property）、concat/string_replace 用法，一个 type 两套实例。只输出代码。`

**完成日期**：2026-10-26
**踩坑记录**：① `string_replace` 是**位置参数列表** `[haystack, needle, replacement]`（str.replace 语义），写 dict 报 `should be called with three or four parameters`；② 失败的 init 留半初始化上下文，紧接着再 init 同名报 `[Errno 2] ... deployments/<id>`——每条负向用例先重置 workdir；③ **原验收修正**：`-i` 传参恒为字符串，整数 input 的 in_range 报的是 `Value is not comparable, the Constraint argument type is 'list'...`（不指 input 名但确实拒绝）——干净报错只有 string 型约束（`violates constraint valid_values(...)`/`violates constraint pattern(...)`）；④ trap 还原勿在阶段内提前删备份（否则中断后源文件停在改写态；对未跟踪文件 `git status` 恒 `??` 验不了内容还原，断言必须写进脚本）；⑤ outputs 是扁平 JSON（值不包壳）可直接 grep，含随机实例后缀的值用模式断言

---

### [x] 项目 3：关系与生命周期——relationships、source/target 操作与多实例

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | `cloudify.relationships.contained_in` / `connected_to` / `depends_on` 语义差异、关系接口 `cloudify.interfaces.relationship_lifecycle`（preconfigure / postconfigure / establish / unlink）的 source/target 两侧操作、脚本里 `ctx source instance runtime-properties` / `ctx target ...` 跨节点取值、`instances: deploy: N` 与 contained_in 的实例数相乘规则、安装顺序由关系推导的 DAG 决定、uninstall 严格逆序 |
| **前置** | 项目 1、2 |
| **验收标准** | install 日志行序断言：db 节点 `Node instance started` 早于 app 节点 create；app 实例 runtime property 含 establish 操作从 db 侧取到的 ip/port；host 节点 `deploy: 3` 时 contained_in 其内的 app 实例数 = 3（`cfy node-instances -b app` 计数）；uninstall 日志中 app 先于 db 删除；对照笔记写进 README（TF `depends_on`/隐式引用、Pulumi `dependsOn`/Output 流 vs TOSCA 五种关系 + 生命周期钩子） |
| **实验目录** | `cloudify/03_relationships/`（✅ 2026-10-26 `all` 全绿连跑两遍：5 相 14 断言——8 实例相乘、db 先于 app、establish 跨节点传值、app 先于 db 删除、零活跃） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「关系与生命周期」。请给我约 150 行蓝图（script 插件）：db + app 两个节点用 connected_to，关系 establish 的 source 操作把 db 的属性写进 app 的 runtime property；host 节点 deploy: 3 且 app contained_in host 演示实例相乘；日志里能看出 install 顺序与 uninstall 逆序。只输出代码。`

**完成日期**：2026-10-26
**踩坑记录**：① dsl_1_5 关系钩子键是 **`source_interfaces`**（`cloudify.interfaces.relationship_lifecycle.establish`），老教程的 `source_operations` 报 `'source_operations' is not in schema`（报错会列出合法键）；② **多实例节点 `get_attribute` 本地模式报错**（`More than one node instance found ... Cannot resolve a node instance unambiguously`），带索引 `[node, attr, 0]` 同样不支持——多实例证据走存储计数；③ bash 里 `$var` 后紧跟全角字符（如 `行 $db_start）`）在 C locale 下把多字节首字节并进变量名 → `db_start\ufffd: unbound variable`，规则：`$var` 后非 ASCII 边界一律 `${var}`；④ 卸载顺序只能断言偏序（app<db、containee 先于 container），独立关系链并发删除时首删实例不固定

---

### [x] 项目 4：工作流与容错——execute_operation、重试策略与失败处理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~130 行 |
| **核心知识点** | 内建工作流 `install` / `uninstall`（`-p ignore_failure=true`）/ `execute_operation`（`-p operation=... -p node_ids=...`）、蓝图里自定义接口（如 `maintenance: backup/restore`）供工作流调用、operation 级 `max_retries` / `retry_interval`、脚本内 `ctx retry_operation "msg"` / `ctx abort_operation "msg"`、CLI `--task-retries` / `--task-retry-interval`、`cfy executions list/get` 定位失败原因 |
| **前置** | 项目 1 |
| **⚠️ 风险** | **`scale` / `heal` 本地模式不可用**（实测报 `Implemented by subclasses`——需 Manager 的存储实现），统一放到项目 12；本项目只做本地支持的工作流，验收别碰 scale |
| **验收标准** | 用计数文件制造"前两次失败第三次成功"的脚本：`max_retries: 3` 下 install 成功且日志含两条 `Retrying operation`；`max_retries: 1` 下同一脚本 install 失败，`uninstall -p ignore_failure=true` 仍能清干净；`execute_operation` 对 2 个实例各执行一次 `maintenance.backup`（日志 task 计数 = 2）；`ctx abort_operation` 的脚本让 install 立即失败且不重试（日志无 Retrying） |
| **实验目录** | `cloudify/04_workflows_retry/`（✅ 2026-10-26 `all` 全绿连跑两遍：5 相 16 断言——重试 3 次成功带 `[retry 1/3]` 证据、execute_operation 双实例、耗尽后 ignore_failure 清零、abort 零重试） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「工作流与容错」。请给我约 130 行（蓝图 + Bash 脚本）：自定义 maintenance.backup 接口 + execute_operation 工作流调用；演示 operation max_retries/retry_interval 与脚本内 ctx retry_operation / ctx abort_operation 的差别（配计数文件制造 flaky 脚本）；uninstall -p ignore_failure=true 清理。附验收命令。只输出代码。`

**完成日期**：2026-10-26
**踩坑记录**：① **dsl_1_5 的 `max_retries`/`retry_interval` 是操作同级键**（与 implementation/inputs 平级），写进 `inputs:` 报 `Expected 'dict' type but found 'integer' type`，且只收裸数字不支持 `get_input`（phases 需要不同重试预算 → 拆成三份蓝图各写死）；② 脚本非零退出 → 按预算重试（日志 `[retry 1/3]`）；`ctx.abort_operation` → 整个执行立即 failed 零重试；③ install 失败后的清理要 `uninstall -p ignore_failure=true`（实测清零）；④ 开发期真踩：Bash/交互 shell 的 cwd 会重置，相对路径在错误目录执行 init 会把**别的实验的蓝图**存进本实验的部署 ID——每次探针/脚本开头必须显式 cd；⑤ `--attr` 查询对无此属性的实例输出空行，助手统一滤空后再断言

---

## 🗂️ 第二阶段：插件与「编排器之上的编排器」——本地模式（项目 5-9）

> **目标**：自写 Python 插件与工作流；用官方插件把 Docker / Terraform / Ansible 纳入同一张 TOSCA 图，跨工具数据经关系与属性流动——这是 Cloudify 区别于 TF/Pulumi 的核心价值

### [x] 项目 5：自写 Python 插件——plugin.yaml + @operation + ctx API + 单测

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行（Python 包 + plugin.yaml + pytest） |
| **核心知识点** | 插件包结构（`setup.py` + `handson_cfy/tasks.py`）、`plugin.yaml`（`plugins:` 段声明 executor + 自定义 `node_types` 把接口操作映射到 `handson_cfy.tasks.func`）、`@operation(resumable=True)`、`ctx.node.properties` / `ctx.instance.runtime_properties` / `ctx.logger` / `ctx.operation.retry()` / `ctx.download_resource()`、操作的 `inputs` 自动注入为 kwargs、`cloudify.mocks.MockCloudifyContext` 写单测 |
| **技术栈** | cloudify-common 7.0.5（已随 CLI 装入 venv）+ pytest；本地安装两条路：`uv pip install -e ./plugin`（推荐，与 venv 一致）或 `cfy init --install-plugins`（⚠️ 开工探活） |
| **前置** | 项目 2 |
| **验收标准** | `pytest` 全绿且断言了 runtime property 写入（非空跑）；蓝图用自定义类型 `hands-on.nodes.HttpCheck`（轮询 URL 直到 200）install 后 runtime property 含 `status_code: 200`；故意传错类型属性在 `cfy blueprints validate` 被拒；`ctx.operation.retry()` 路径有单测覆盖（首次 503 → retry → 200） |
| **实验目录** | `cloudify/05_my_plugin/`（✅ 2026-10-27 `all` 全绿连跑两遍：pytest 4 路径 + 10 断言——status_code=200、渲染落盘、required 缺失被拒、uninstall 真删文件） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「自写插件」。请给我约 180 行：handson_cfy 插件包（setup.py + tasks.py + plugin.yaml，dsl_1_5 节点类型），实现 hands-on.nodes.HttpCheck（轮询 URL、失败 ctx.operation.retry、成功写 runtime property status_code）与 hands-on.nodes.RenderedFile（模板渲染落盘）；pytest 用 MockCloudifyContext 覆盖成功/重试/属性三条路径。只输出代码。`

**完成日期**：2026-10-27
**踩坑记录**：① **implementation 首段必须匹配 plugins: 里声明的插件名**（`handson.handson_plugin.tasks.X`，对照官方 `docker.docker_plugin.tasks.X`）——否则 validate 报 `Could not extract plugin`；② 本地执行不需要 wagon：插件 `pip install -e` 进 CLI venv，本地引擎直接 import；③ MockCloudifyContext **必须给 node_id**（否则 deployment 上下文，ctx.node 抛错）；④ `ctx.operation.retry()` 在 mock 里不抛异常——插件用 `raise OperationRetry(msg)`（语义同、可测）；**@operation 装饰器脱离引擎直调会吞 OperationRetry**——单测测内层函数；⑤ **dsl_1_5 不校验属性值类型**（integer 填 string 属性照样过），解析期真闸门是 required 缺失（报错干净）；⑥ `mock.patch(side_effect=单个对象)` 报 not-an-iterator，要传列表

---

### [x] 项目 6：自定义工作流——Python @workflow 任务图与并行度

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | 插件包里 `@workflow def rolling_restart(ctx, batch, **kw)`、`ctx.graph_mode()` + `TaskDependencyGraph`、`ctx.nodes` / `node.instances` 遍历、`instance.execute_operation()` 造任务、`sequence()` 串行 vs forkjoin 并行、蓝图 `workflows:` 段声明 parameters（类型/默认值/约束）并 mapping 到插件、`cfy executions start rolling_restart -p batch=1` |
| **前置** | 项目 3（多实例）、5（插件包承载 workflow 模块） |
| **验收标准** | `rolling_restart -p batch=1` 时日志时间戳证明 3 个实例逐个重启、无时间重叠；`batch=3` 时三个 restart 任务的开始时间间隔 < 1 秒（并行）；`-p batch=-1` 被 parameters 约束拒绝；对照笔记写进 README：TF/Pulumi 没有"第二工作流"概念（Day-2 只能整把 apply/up），这是 TOSCA 编排器的本质差异点 |
| **实验目录** | `cloudify/06_custom_workflow/`（✅ 2026-10-27 `all` 全绿连跑两遍：11 断言——batch=1 串行 3.02s/3 批次、batch=3+池 3 并发 1.01s/1 批次、非法 batch 自检拒绝） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「自定义工作流」。请给我约 150 行：在项目 5 的插件包里加 @workflow rolling_restart（graph_mode + sequence/forkjoin，batch 参数控制每批实例数，执行 restart 操作），蓝图的 workflows 段带约束声明，附 batch=1（串行）与 batch=3（并行）的日志时间戳验收命令。只输出代码。`

**完成日期**：2026-10-27
**踩坑记录**：① **原验收修正**：`parameters.constraints` 本地引擎不校验（batch=-1 照常启动）→ 改为工作流入口自检 raise（执行失败 + 消息进日志）；并行断言成立但前提有二——**每实例一条 sequence**（把同批实例塞进同一条 sequence 就是串行链）+ **`--task-thread-pool-size` 显式给**（CLI 默认 1，引擎常量 8 不生效于 CLI）；② 图并发 = 无依赖任务 + 池容量，两个条件缺一不可；③ `ctx.node_instances` 无序，分批前 sorted；④ 无 forkjoin 助手（7.0.5 用 subgraph/sequence/add_dependency 组合）

---

### [x] 项目 7：Docker 插件——编排容器与镜像

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | 官方 `cloudify-docker-plugin` 2.0.16 的 `cloudify.nodes.docker.container`（`client_config.docker_sock_file` + `resource_config.image_tag` / `container_args`）、`cloudify.nodes.docker.image`（从 Dockerfile `build_image`）、容器 `connected_to` 容器把后端 ip/port 传给前端、runtime property 里的容器详情、uninstall → `remove_container` 零残留 |
| **技术栈** | 插件源码 zip 走 `github.com/.../archive/refs/tags/2.0.16.zip`（✅ 实测可下）；**必须 `--no-deps` 安装**后手补 `docker fabric patchwork` + `cloudify-utilities-plugins-sdk --no-deps`（✅ 实测 import 与执行全通）；本地模式 import 用 vendor 的 `plugin_1_5.yaml`，不能用 `plugin:` 短路径（那是 Manager 专属，解析已上传插件） |
| **前置** | 项目 3 |
| **⚠️ 风险** | 插件 `install_requires` 写的是 `fusion-common`（Dell 内部改名，PyPI/GitHub 均无此包）→ 直装必失败，`--no-deps` 是唯一绕法；`create_container` 不做 pull（`containers.create` 直接用本地镜像）→ Docker Hub 直连不通，**只用本机已有镜像**（`nginx:1.29-alpine` 等 ✅） |
| **验收标准** | install 后 `docker ps` 见 2 个指定名字容器、`curl :28110` 返回 200；后端容器的 ip/port 出现在前端容器 runtime property（关系传值）；uninstall 后 `docker ps -a` 零残留；三方对照表（labs/01 TF docker provider / pulumi/01 / 本项目同题）写进实验 README |
| **实验目录** | `cloudify/07_docker_plugin/`（✅ 2026-10-27 `all` 全绿连跑两遍：11 断言——双容器 curl 200、establish 抓 api bridge IP 写进 web、outputs、uninstall 零残留） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「Docker 插件」。请给我约 150 行蓝图（vendor docker-plugin.yaml，--no-deps 安装已就绪）：api 容器 + web 容器（nginx:1.29-alpine），web connected_to api，端口 28110/28111，docker_sock_file: /var/run/docker.sock；outputs 取 web 容器 runtime property；附 install/curl/uninstall/零残留验收命令。只输出代码。`

**完成日期**：2026-10-27
**踩坑记录**：① `--no-deps` 装 2.0.16 后手补 docker/fabric/patchwork + utilities-sdk（`fusion-common` 不存在）；② 插件 runtime properties：`container`（64 位长 ID）、`container_args`、`container_info`（**只是 repr 字符串**非结构化）；③ **OrbStack 顶层 `NetworkSettings.IPAddress` 是 None**——bridge IP 在 `Networks.<net>.IPAddress`，establish 里用 docker SDK 遍历 Networks；④ `create_container` 不 pull（只用本地镜像）——国内网络下是优点；⑤ uv 从 tarball 装包要求**文件名与元数据 name 一致**（cfy-docker-2.0.16.tar.gz 会报 metadata mismatch）；⑥ github.com archive 偶发超时，codeload.github.com 的 tar.gz 更稳

---

### [x] 项目 8：Terraform 插件——把 labs/02 的模块当一个节点

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | `cloudify-terraform-plugin` 0.21.6 的 `cloudify.nodes.terraform`（二进制节点：`use_existing_resource: true` 指向本机 terraform 1.15.8）+ `cloudify.nodes.terraform.Module`（`source` 本地 zip、`variables` 来自 inputs、本地 backend）、TF outputs → runtime_properties.outputs → 其他节点消费、`reload_terraform_template`（换模块源重 apply）/ `refresh_terraform_resources`（对账漂移）工作流、tfstate 在部署工作目录的托管位置 |
| **技术栈** | 同项目 7 的 `--no-deps` 装法（⚠️ 开工先读 `setup.py` 补真实依赖）；被编排对象 = labs/02 的 TF 模块（docker provider 起容器） |
| **前置** | 项目 7；devops.md 项目 1-2 已完成 |
| **⚠️ 风险** | 插件默认从 `releases.hashicorp.com` 下载 terraform 二进制（国内不通）→ 必须 `use_existing_resource`；TF docker provider 要用的镜像同样需本机已有 |
| **验收标准（实做版）** | script 包装主线：install 后 tfstate 落在部署工作目录、TF outputs 进 runtime properties（含容器名）、容器 28112 curl 200；`execute_operation` 传 `replicas=2` 增量 apply 容器 1→2；手删容器后 `plan -detailed-exitcode` 检出漂移并收敛重建；uninstall 的 delete 钩子 destroy 零残留。**官方插件负向留证**：validate 通过但 install 秒败（`LOCAL_REST_CERT_FILE` → 伪造证书后 `inet_pton(None)`；劫持 `REST_HOST` 则无限挂起） |
| **实验目录** | `cloudify/08_terraform_plugin/`（✅ 2026-10-27 `all` 全绿连跑两遍：16 断言——四能力 + 官方插件负向） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「Terraform 插件」。请给我约 150 行（vendor terraform 插件 yaml）：cloudify.nodes.terraform 用本机 terraform（use_existing_resource），Module 节点 source 指向 labs/02 的 TF 模块 zip、variables 走 inputs；演示 outputs 流入另一个节点、reload_terraform_template 重 apply、refresh_terraform_resources 漂移检出。只输出代码。`

**完成日期**：2026-10-27
**踩坑记录**：① **官方 terraform 插件本地不可用**（三道 Manager 硬依赖实测，见验收负向）——本地用 script 插件包装本机 terraform，蓝图接口形状与官方对齐，上 Manager 可平移；② **tfstate 必须复用同一工作目录**：每次 rm -rf 会让 TF 不认识存量容器 → 名字冲突；有 state 就增量 apply；③ **每次 plan/apply 都要显式 -var replicas=<当前值>**——漏传落回模块默认值 1，drift 收敛会把多起的容器当多余资源删掉（实测 web-1 被删）；④ `cfy -p` 整串先试 JSON：dict 参数用**一个 JSON 对象包全部**（key=value 形式把 dict 值留成字符串 → `'str' object has no attribute 'items'`）；⑤ operation inputs 与 operation_kwargs 传同名键报 `Duplicate definition` → 调用侧 `allow_kwargs_override: true` 或蓝图中该操作不声明此 input；⑥ `registry.terraform.io` 本网络被 RST → filesystem_mirror 复用 labs/01 的 provider 二进制（按 darwin_arm64 目录布局）；⑦ uninstall 后 runtime property 不可读（实例记录被删）——delete 钩子的产出只能靠日志断言（`tf destroy done`）；⑧ 插件真实依赖链 --no-deps 后补 networkx/deepdiff/psutil/xmltodict

---

### [x] 项目 9：⛓️ Ansible 插件——用 labs/06 的 Role 配置 Docker 插件起的容器

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | `cloudify-ansible-plugin` 3.2.7 的 `cloudify.nodes.ansible.Playbook`（`playbook_path` / `sources` 内联 inventory / `run_data` 变量）、`ansible_connection: docker` 免 SSH 直接配置容器、`connected_to` 关系：容器节点先起 → playbook 节点从其 runtime property 取容器名当 inventory host、幂等重跑（`changed=0`）、复用本机 ansible-core 2.21.3 |
| **技术栈** | 同 `--no-deps` 装法（⚠️ 开工探活）；本机 ansible-core 2.21.3 ✅；被编排对象 = 项目 7 的容器 + labs/06 的 role（挑无 systemd 依赖的 task 子集） |
| **前置** | 项目 7；devops.md 项目 6 已完成 |
| **⚠️ 风险** | 插件默认自建 venv pip 装 ansible（慢且可能失败）→ 配置指向本机 `ansible-playbook` 可执行文件；`ansible_connection: docker` 要求容器内有 python——本机 nginx alpine 镜像没有，需在项目 7 的 image 节点里基于 `nginx:1.29-alpine` 加装 python3（Alpine CDN 可达，或换本机已有的含 python 基础镜像） |
| **验收标准** | 单次 install 内日志行序：容器 `created` 先于 playbook 执行；`docker exec <容器> cat /etc/motd`（或 role 写入的目标文件）内容符合预期；对 playbook 节点重跑 `execute_operation` 得 `changed=0`（幂等）；uninstall 后容器与插件工作目录零残留 |
| **实验目录** | `cloudify/09_ansible_plugin/`（✅ 2026-10-27 `all` 全绿连跑两遍：12 断言——行序、首次 changed=2、重跑 changed=0、docker exec 内容、零残留 + 官方插件负向） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「Ansible 插件」。请给我约 150 行（vendor ansible 插件 yaml）：项目 7 的容器节点 + cloudify.nodes.ansible.Playbook 节点（sources 内联 inventory 用 ansible_connection: docker，host 名从容器的 runtime property 取），playbook 来自 labs/06 role 的无 systemd 子集；演示首次 changed>0、重跑 changed=0。只输出代码。`

**完成日期**：2026-10-27
**踩坑记录**：① **官方 ansible 插件本地秒败**（`cloudify_ansible.tasks.precreate` → `join()...NoneType`，Manager 文件系统路径缺失，与 08 同族）——主线 script 包装本机 ansible-core 2.21.3 + `community.docker 5.3.0` collection（`ansible_connection: docker` 的前提，本机已装）；② **双上下文互斥**：关系上下文访问 `ctx.node/ctx.instance`、节点上下文访问 `ctx.source/ctx.target` 都直接抛错——establish 与 execute_operation 重跑共用一个脚本时必须先分派上下文，重跑从自身 runtime properties 回读 `target_container`；③ `cloudify.nodes.Root` 不接受自定义 properties（dsl_1_5 严格 schema）——挂属性要自定义 node_types；④ 容器需自带 python3（`python:3.12-slim`，nginx-alpine 没有）；⑤ script 插件临时目录**只含被执行的脚本**——playbook/inventory 由主脚本 stage 到蓝图外固定路径；⑥ 配置动作别挂 create 钩子（node 上下文无 target，install 必炸），只挂 establish + maintenance

---

## 🗂️ 第三阶段：Manager 平台能力——AIO 社区版（项目 10-13）

> **目标**：跑起 Manager，把前两阶段的蓝图托管上去；掌握 REST / 控制台 / secrets / 标签治理 / deployment update / scale / heal / 快照 / 插件上传——从「命令行引擎」升级为「平台」

### [ ] 项目 10：Manager 启动与首个托管部署（⚠️ 闸门：待镜像，见下）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行（docker run/compose + 脚本） |
| **核心知识点** | AIO 社区镜像 7.0.1（`--privileged` + cgroup 挂载跑 systemd；宿主端口 28100→80 / 28101→443）、`cfy profiles use localhost:28100 -u admin -p admin -t default_tenant`、`cfy status`（REST / PostgreSQL / RabbitMQ / mgmtworker / nginx 全 Active）、`cfy blueprints upload` → `deployments create` → `executions start install` → `cfy events list`、Console（http://localhost:28100，admin/admin）、REST `/api/v3.1/`（curl + `Tenant: default_tenant` 头）、容器重启后状态持久化 |
| **技术栈** | `docker.1ms.run/cloudifyplatform/community-cloudify-manager-aio:7.0.1`（✅ manifest 实测有原生 linux/arm64，压缩 1.63GB；amd64 0.83GB）；启动实测结论见文末速查表 |
| **前置** | 项目 1（拿它的蓝图上传） |
| **⚠️ 风险（2026-10-28 闸门实测）** | ① **镜像获取三路全部穷尽**：换时段重拉（4 次，大层均截断）、镜像源限速（1ms CDN ~0.1MB/s，1.63GB 需 18h）、他机 save+load（无他机）→ **自救脚本已实现**：`cloudify/scripts/fetch_manager_image.sh`（mirror token 流程 + 逐 blob 断点续传 + sha256 校验 + 组装 docker-archive + docker load，Range 支持已实测 307→CDN），网络恢复/有代理/有他机时执行即可开工；② 首次启动需 3-5 分钟，`cfy status` 全 Active 前 upload 会 502；③ 蓝图里 vendor 的相对路径 import 在 Manager 同样可用（Manager 端还可用短路径 `cloudify/types/types.yaml`——它自带 spec 资源，实验蓝图 bp.yaml 已按短路径写好）；④ systemd 容器需要 `--tmpfs /run --tmpfs /run/lock --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw` |
| **验收标准** | `cfy status` 全部服务 `Active`；项目 1 蓝图 `deployments create` + `install` 跑到 `terminated`，`cfy deployments outputs` 与本地模式结果一致；`curl -su admin:admin -H "Tenant: default_tenant" http://localhost:28100/api/v3.1/deployments` 的 JSON 含该部署；`docker restart` Manager 容器后 `cfy deployments list` 仍见部署（持久化） |
| **实验目录** | `cloudify/10_manager_aio/` |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「Manager 启动」。请给我约 120 行（run-manager.sh + 断言脚本）：按 --privileged/--cgroupns=host/--tmpfs 参数起 community-cloudify-manager-aio:7.0.1（28100/28101），轮询 cfy status 全 Active，然后 profiles use、upload 项目 1 蓝图、deployments create + install、outputs 与 REST curl 断言、重启容器验证持久化。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 11：Secrets 与治理元数据——secrets store、labels、filters、deployment groups（⚠️ 闸门：待镜像，见下）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~100 行 |
| **核心知识点** | `cfy secrets create/update/export/import`（加 `--secret-file` 避免进 shell 历史）、蓝图内 `{ get_secret: db_password }`、secret 的 `--visibility`（private / tenant / global）、`cfy deployments create --labels env:dev,team:a`、`cfy deployments list --filter-id`（labels filter）、`cfy deployment-groups` 对组内多部署批量 `execute_operation`、`cfy sites` 逻辑分组、Console 的 filter 视图 |
| **前置** | 项目 10、4（用 script 插件蓝图，先不依赖 Manager 插件） |
| **⚠️ 风险** | **社区版单用户单租户**：`cfy tenants/users/user-groups/ldap` 命令虽存在，Manager 会拒绝（Premium 专属，官方文档确认）→ 多租户 / RBAC 列入跳过项，不作验收 |
| **验收标准** | `cfy secrets create db_password` 后，蓝图 `get_secret` 的值出现在脚本 env，且 `cfy events list` 全文 grep 明文 0 命中；`secrets update` 新值后重跑 `execute_operation` 取到新值；按 label `env:dev` / `env:prod` 各过滤出 2 / 1 个部署；deployment group 对组内 2 个部署一次性 `execute_operation`（`executions list` 见 2 条执行） |
| **实验目录** | `cloudify/11_secrets_labels/` |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「Secrets 与治理」。请给我约 100 行（蓝图 + 脚本）：Manager 上 secrets create/export/import、蓝图 get_secret 注入脚本 env（events 全文 grep 明文断言 0 命中）、deployments 打 env/team labels + filter 过滤、deployment-groups 批量 execute_operation。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 12：Day-2 运维——deployment update、scale、heal 与快照（⚠️ 闸门：待镜像，见下）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | `cfy deployments update -d X -b v2`（新增节点 / 改属性 → update 工作流只处理 diff，原实例 id 不变）、`cfy executions start scale -d X -p scalable_entity_name=web -p delta=2`（本地模式不可用，Manager 专属）、`heal -p node_instance_id=`（重建单实例子图、保持实例 id）、`cfy executions cancel` / `--kill`、`cfy snapshots create/download/upload/restore`（restore 必须到干净 Manager）、选做：`cfy deployments schedule create` 定时执行（⚠️ 开工探活） |
| **前置** | 项目 10、13（scale/heal 的"真实资源"用 docker 插件容器最直观；若 13 未通先用 script 插件写文件模拟） |
| **⚠️ 风险** | snapshot restore 到**干净** Manager → 起第二个 AIO 容器（端口 28102）演示，两个 Manager 同时跑内存要给够（各 ≥4GB）；scale/heal 深度依赖部署状态，先用小蓝图练手 |
| **验收标准** | update 后新增节点实例出现且原实例 id 逐字不变；`scale delta=2` 后 web 实例数 +2、`delta=-1` 回缩 1（`cfy node-instances -d X` 计数）；手动破坏一个实例（`docker rm -f` 容器）后 `heal` 重建且实例 id 保持；`snapshots create` → 第二个干净 Manager `restore` 后 `cfy deployments list` 与 secrets 数量和原 Manager 一致 |
| **实验目录** | `cloudify/12_day2_update_scale_heal/` |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「Day-2 运维」。请给我约 150 行（蓝图 v1/v2 + 脚本）：deployments update 只动 diff（实例 id 不变断言）、scale ±delta、heal 重建被 docker rm -f 的容器（实例 id 保持断言）、snapshots create → 干净 Manager restore → 部署与 secrets 一致断言。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 13：⛓️ 插件上平台——wagon 打包、上传与 aarch64 自建攻坚（⚠️ 闸门：待镜像，见下）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行（脚本为主） |
| **核心知识点** | wagon 格式（wheel 集合 + 平台元数据）、`wagon create -s <源码 zip>` 打包、`cfy plugins upload x.wgn -y plugin_1_5.yaml`、Manager 端蓝图改用 `imports: - plugin:cloudify-docker-plugin`、`cfy plugins list/delete`、平台匹配规则（`manylinux-py311-none-linux_x86_64` vs aarch64）、mgmtworker 需挂载宿主 `/var/run/docker.sock` 才能跑 docker 插件任务 |
| **前置** | 项目 5（自写插件）、7（docker 插件）、10 |
| **⚠️ 风险** | **六个官方插件 wagon 全部只有 `linux_x86_64`**（实测：utilities 2.0.6 / helm 0.4.11 / docker 2.0.16 / k8s 2.13.31 / terraform 0.21.6 / ansible 3.2.7，无 aarch64）→ arm64 Manager 直接上传被拒。两条路：(A) **攻坚**——在 arm64 Manager 容器内 `pip install wagon`（清华源）`wagon create` 自建 aarch64 wagon；先把源码 `setup.py` 里的 `fusion-common` 换成 `cloudify-common` 再打；cryptography/bcrypt 在 PyPI 有 aarch64 manylinux 轮子，大概率免编译；(B) **fallback**——换 `--platform linux/amd64` 的 AIO 镜像走 OrbStack Rosetta（0.83GB），x86_64 官方 wagon 直接可用，代价是 Manager 启动与执行更慢。自写插件（项目 5，纯 Python）打出 `py311-none-any` wagon 两边通用 |
| **验收标准** | 项目 5 自写插件的 wagon 上传成功、`cfy plugins list` 可见，Manager 上用它蓝图 install 成功；x86_64 docker 插件 wagon 上传到 arm64 Manager 被拒且记录原文错误（负向验收）；A 或 B 任一路线下，docker 插件在 Manager 上 install 出真容器（宿主 `docker ps` 可见）；文末速查表写明走了哪条路 |
| **实验目录** | `cloudify/13_plugins_wagon/` |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「插件上平台」。请给我约 120 行脚本：wagon create 打包项目 5 自写插件（py311-none-any）并 plugins upload + 蓝图改 plugin: 导入 + install；负向测试 x86_64 wagon 上传 arm64 Manager 的报错记录；docker 插件 aarch64 自建（容器内 wagon create，setup.py 换 fusion-common→cloudify-common）或 amd64 Rosetta fallback 二选一。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第四阶段：Kubernetes 与交付闭环（项目 14-16）

> **目标**：K8s 纳入编排图；蓝图当代码进 CI 门禁；🏁 一个蓝图跨 Terraform / Docker / Ansible / Kubernetes 四个世界收官

### [x] 项目 14：Kubernetes 插件——在 kind 上部署并滚动更新

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | `cloudify-kubernetes-plugin` 2.13.31 的 `cloudify.kubernetes.nodes.Master`（kubeconfig 内容 / context 指定）+ `cloudify.kubernetes.resources.FileDefinedResource`（Deployment + Service 清单文件）/ `ResourceDefinition`（内联 manifest）、`update_resource_definition` 工作流改镜像 tag 触发滚动、专用集群 `kind create cluster --name cfy-lab`（extraPortMappings 28120→30080）、镜像导入 kind 节点 |
| **技术栈** | 同 `--no-deps` 装法（⚠️ 依赖 `kubernetes` Python client，开工探活）；kind 0.32.0 ✅ / kubectl 1.33.9 ✅；本地模式或 Manager（项目 13 成功则上 Manager） |
| **前置** | 项目 7；pulumi.md 项目 9 的 kind 经验 |
| **⚠️ 风险** | kind 节点不共享宿主镜像且 docker.io 拉不动 → 沿用 pulumi/09 教训：`docker save | docker exec -i 节点 ctr -n k8s.io images import -`；本机已有 8 个 kind 集群，所有 K8s 节点必须显式指定 context `kind-cfy-lab` |
| **验收标准（实做版）** | install 后 `kubectl --context kind-cfy-lab get deploy,svc` 可见（Service NodePort 30080→宿主 28120 curl 200）；滚动更新走 `kubectl set image`（官方 update_resource_definition 工作流 422 负向留证）→ 新 RS ready/旧 RS 缩 0/宿主仍 200/插件 poststart 重读；uninstall 插件 delete 422 → kubectl 兜底零残留 |
| **实验目录** | `cloudify/14_kubernetes_plugin/`（✅ 2026-10-28 `all` 全绿两遍：14-16 断言；官方 k8s 插件**本地模式可用**——与 terraform/ansible 不同族） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「Kubernetes 插件」。请给我约 150 行（vendor kubernetes 插件 yaml）：Master 节点连 kind-cfy-lab（显式 context），FileDefinedResource 部署 Deployment+Service（nginx:1.29-alpine 已导入 ctr），NodePort 映射 28120；演示 update_resource_definition 改 tag 触发 rollout 与 uninstall 零残留。只输出代码。`

**完成日期**：2026-10-28
**踩坑记录**：① 依赖修复链：`kubernetes==26.1.0` 必须降级（30+ 的 pydantic v2 强校验报 Missing required argument）+ azure-mgmt-containerservice/azure-identity/google-auth（cloudify_azure_sdk 的 AKS 分支 import）+ `cloudify_importer` stub（内部化裸 import 零使用）+ `mgmtworker` stub（Manager 兜底 import，符号 NotImplementedError）+ 升级 requests-toolbelt/bottle/jinja2（py3.11 兼容）；② **升级老包时 uv 会顺手把 cloudify-common 降级**（cloudify-types 的钉子）→ CLI 自身报 `ipv6_url_compat` ImportError——装完必跑 cfy --version 自检；③ kubeconfig 用**外部地址**（internal 的容器域名本地解析不了），改后必须重 `cfy init`；④ 滚动更新前新镜像也要导入 kind 节点（ImagePullBackOff 实测）；⑤ 官方 update 工作流的 changes 必须带 kind+metadata.name（`update_with_additions` 靠它匹配，不带**静默丢弃**）；即便如此 PUT 全量 definition 仍 422 min-availability → 滚动更新走 kubectl + 插件 poststart 重读收敛；⑥ `kind get clusters | grep -q` 的 SIGPIPE 假失败（pipefail）——用字符串包含判断；⑦ `code=$(curl ...)` 裸赋值的退出码会触发 set -e 静默退出——探测命令一律 `|| true` + 轮询

---

### [x] 项目 15：蓝图即代码——validate / cfy-lint / 单测 / act 本地 CI 门禁

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（workflow + 脚本 + 测试） |
| **核心知识点** | `cfy blueprints validate`（无 Manager 可用 ✅，坏 type 报 `path:`）、`cfy-lint 0.0.37`（PyPI ✅：蓝图写法 lint）、插件 pytest（项目 5）当单元测试、本地模式 install→断言→uninstall 冒烟当集成测试、GitHub Actions 三 job（lint+validate / unit / smoke）在 `act` 0.2.89 本地跑（复用 cicd/01 回路）、PR 门禁语义 |
| **前置** | 项目 5、7；cicd.md 项目 1（act）已完成 |
| **⚠️ 风险** | act 容器内 pip 装 cloudify 走清华源；docker 冒烟 job 需挂宿主 socket（`--container-options "-v /var/run/docker.sock:/var/run/docker.sock"`，沿 cicd/01 经验 flag 全放根层级）；cfy-lint 对 dsl_1_5 的规则覆盖以实测为准 |
| **验收标准（实做版）** | `act` 主 workflow 三 job 全绿（lint+validate / 插件 pytest / 本地回路冒烟）；两条负向 workflow（坏蓝图、坏断言）act 退出码均非 0（门禁真的会拦）；本套件容器零残留 |
| **实验目录** | `cloudify/15_blueprint_ci/`（✅ 2026-10-28 `all` 全绿两遍：20 断言；镜像 python:3.11-slim） |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「蓝图即代码」。请给我约 150 行：GitHub Actions workflow（act 本地跑）三 job——cfy-lint + blueprints validate、插件 pytest、本地模式 install→curl→uninstall 冒烟（挂宿主 docker.sock）；配三个"故意弄坏"的负向用例触发各自红灯。只输出代码。`

**完成日期**：2026-10-28
**踩坑记录**：① **act 的 workspace 只复制 git tracked 文件**——untracked 的 cloudify/ 在容器里是空目录（/tmp 临时目录复现实锤）→ `--bind` 直挂（cicd/01 同款）；② `--pull` 默认 true（网络抖动连本地镜像都 Set up 失败，bool 要写 `--pull=false`）；③ job 容器默认挂 docker.sock——自己再挂就 `Duplicate mount point`，且 `--container-daemon-socket -` 会把 workspace 复制也禁掉（同走一个 socket）；④ 容器装 cloudify 三道闸：`--break-system-packages`（PEP 668）、**显式钉 `cloudify-common==7.0.5`**（7.0.5 只有 sdist，pip 自由解析会抓到老版本的 py2 语法 sdist）、`PIP_ONLY_BINARY: "pyyaml,PyYAML"`（sdist 构建拉 PyYAML sdist 撞 Cython 3 的 `cython_sources` 错误；只对 pyyaml 强制，cloudify 本体必须放行 sdist）；⑤ 镜像用 **python:3.11-slim**（act-latest 的 py3.12 与 cloudify 7.0.5 连环不兼容）；⑥ cfy-lint 0.0.37 与新版 click 不兼容（get_fix）→ `|| true` 不设红，validate 才是闸门；⑦ `--ignore-installed cryptography`（debian 管理）；⑧ act 输出的 job 名空格 padding——断言匹配 ` *`；⑨ 被测插件必须在 workspace 内（stage 拷贝，gitignore）；⑩ act 容器滞留 → 套件容器按名兜底清理

---

### [x] 项目 16：🏁 混合编排终局——一个蓝图跨 Terraform / Docker / Ansible / Kubernetes

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心知识点** | 单蓝图四插件共存：Terraform 模块（docker network + volume）→ Docker 容器（nginx，`connected_to` TF 节点读其 outputs）→ Ansible playbook（docker 连接配置容器）→ Kubernetes ConfigMap + Deployment（`concat` 拼出 nginx URL 注入）→ 自写 `HttpCheck`（项目 5）端到端探活；关系驱动的安装顺序与跨工具属性流；项目 6 的 `rolling_restart` 在终局部署上执行；Manager 托管（项目 13 成功路线）或本地模式 fallback |
| **前置** | 项目 5、6、7、8、9、14（若上 Manager 还需 10、13） |
| **验收标准** | 单次 `install` 四世界全建成且日志行序 TF → Docker → Ansible → K8s → HttpCheck；`HttpCheck` 的 runtime property `status_code=200` 且 outputs 的 URL 由 ≥3 个节点属性 `concat` 而来；`rolling_restart -p batch=1` 在终局部署执行成功；`uninstall` 后 docker / kind / tfstate 三处零残留（`docker ps -a`、`kubectl get all -n cfy`、部署工作目录无 `.tfstate`） |
| **实验目录** | `cloudify/16_hybrid_finale/` |

**🤖 开始提示词**：
> `我要开始 Cloudify 项目「混合编排终局」。请给我约 250 行蓝图：同图编排 TF 模块（network+volume）、docker 容器（读 TF outputs 挂网，28125）、ansible playbook（docker 连接配置）、kind 上的 ConfigMap+Deployment（concat 注入 URL）、自写 HttpCheck 探活；附 install 行序断言、rolling_restart、三世界零残留验收。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 📅 周计划

| 周次 | 内容 | 项目数 |
|:---|:---|:---:|
| **第 1 周** | 项目 1-3（本地回路 / 类型与函数 / 关系与生命周期） | 3 |
| **第 2 周** | 项目 4-6（工作流容错 / 自写插件 / 自定义工作流） | 3 |
| **第 3 周** | 项目 7-9（Docker / Terraform / Ansible 插件） | 3 |
| **第 4 周** | 项目 10-12（Manager 启动 / Secrets 治理 / Day-2 运维） | 3 |
| **第 5 周** | 项目 13-14（wagon 攻坚 / Kubernetes） | 2 |
| **第 6 周** | 项目 15-16（CI 门禁 / 🏁 混合终局） | 2 |

## 🏆 里程碑

- [x] **完成项目 1-4** → 「TOSCA 建模者」：零 Manager 跑通蓝图回路，节点/关系/工作流/容错心智模型建立，TF ↔ Pulumi ↔ Cloudify 逐条对照无障碍（2026-10-26，四实验连跑两遍全绿）
- [x] **完成项目 5-9** → 「插件与编排工程师」：自写插件与工作流；Docker / Terraform / Ansible 纳入同一张 TOSCA 图（2026-10-27，五实验连跑两遍全绿；官方 terraform/ansible 插件本地模式负向留证）
- [ ] **完成项目 10-13** → 「平台运维者」：Manager 托管、secrets 与标签治理、update / scale / heal / 快照、插件打包上平台
- [x] **完成项目 14-16** → 「混合编排架构师」：K8s 纳入、蓝图即代码 CI、🏁 单蓝图跨四世界交付（2026-10-28，闸门之下完成的阶段四；项目 10-13 闸门见上）

## 📝 每日日志

| 日期 | 项目 | 耗时 | 收获 | 踩坑 |
|:---|:---|:---:|:---|:---|
| | | | | |

## 🔧 环境配置

```bash
# 0. 已就绪（✅ 2026-10-26 实测）
#    docker 29.8.2（OrbStack，aarch64，VM 内存 16GB）、uv 0.13.0
#    python3.11 3.11.15（~/.local/bin，cfy 专用）/ python3.12 3.12.13 / python3.13 3.13.9（anaconda，❌ 跑不了 cfy）
#    pip 清华源（含 cloudify 7.0.5 / cloudify-utilities-plugins-sdk 0.0.130 / cfy-lint 0.0.37）
#    terraform 1.15.8、ansible-core 2.21.3、kind 0.32.0（8 个集群在跑）、kubectl 1.33.9、helm 4.2.2、act 0.2.89、node 22
#    本机镜像：nginx:1.29-alpine / nginx:1.27-alpine / nginx:latest（Docker Hub 直连不通，插件只用已有镜像）

# 1. 需安装（项目 1 之前）—— cfy 必须 Python 3.11
cd cloudify && uv venv --python 3.11 .venv && source .venv/bin/activate
uv pip install cloudify==7.0.5 "setuptools<81"   # 3.13 报 No module named 'cgi'；不补 setuptools 报 pkg_resources 缺失
cfy --version                                     # Cloudify CLI 7.0.5（pkg_resources deprecation 警告可忽略）

#    取 types.yaml（raw.githubusercontent 不可达，走 Contents API）：
curl -sL -H "Accept: application/vnd.github.raw+json" \
  "https://api.github.com/repos/cloudify-cosmo/cloudify-manager/contents/resources/rest-service/cloudify/types/types.yaml?ref=7.0.5-build" \
  -o cloudify/_vendor/types.yaml                  # 各实验的 vendor/ 拷贝或软链此文件
export CFY_WORKDIR=$HOME/.cfy-handson             # 每次实验都设；绝不放蓝图目录内

# 2. 按阶段用到时装
#    项目 7/8/9/14 官方插件——必须 --no-deps（fusion-common 不存在），以 docker 插件为例：
curl -sL -o /tmp/docker-plugin.zip https://github.com/cloudify-cosmo/cloudify-docker-plugin/archive/refs/tags/2.0.16.zip
uv pip install --no-deps /tmp/docker-plugin.zip \
  && uv pip install "docker>=5.0.3" "fabric>=2.5.0" "patchwork>=1.0.1" \
  && uv pip install --no-deps cloudify-utilities-plugins-sdk
#    terraform 0.21.6 / ansible 3.2.7 / kubernetes 2.13.31 同法，真实依赖按各自 setup.py 补（⚠️ 开工探活）
#    项目 10/12（Manager；镜像 1.63GB arm64 / 0.83GB amd64；大层断流见清单头与速查表）：
docker pull --platform linux/arm64 docker.1ms.run/cloudifyplatform/community-cloudify-manager-aio:7.0.1
#    项目 14：kind create cluster --name cfy-lab --config kind-28120.yaml   # extraPortMappings 28120→30080
#    项目 15：uv pip install cfy-lint pytest

# 3. 每项目开工前
docker info --format '{{.ServerVersion}}'         # docker 活着
source cloudify/.venv/bin/activate && cfy --version
cfy status                                        # 项目 10+：Manager 全 Active
```

### 宿主端口（Cloudify 系列统一 281xx 段，与根 README 端口分配表错峰）

| 端口 | 归属 |
|:---|:---|
| 28100 / 28101 | Manager HTTP / HTTPS（项目 10-13） |
| 28102 | 第二个干净 Manager（项目 12 快照恢复） |
| 28110 / 28111 | 项目 7 web / api 容器 |
| 28112 / 28113 | 项目 8 TF 模块容器 |
| 28120 | 项目 14/16 kind cfy-lab NodePort 映射（30080，两者共用） |
| 28130 / 28131 | 项目 16 web（ansible+HttpCheck）/ TF api 容器 |

## ⚠️ 与已有清单的关系

| 已有清单 | 关系 |
|:---|:---|
| **devops.md 项目 1-4**（Terraform，已完成） | 项目 8 把 labs/02 模块当 TOSCA 节点编排；TF 本身不重讲，关系与状态模型的对照写进项目 8 笔记 |
| **devops.md 项目 6-7**（Ansible / Molecule，已完成） | 项目 9 用 labs/06 的 role 配置容器；Ansible 语法不重讲，Molecule 测 role 与 Cloudify 编排 role 的层次差异写进笔记 |
| **devops.md 项目 21**（Flux GitOps，⬜ 未做） | 项目 14 对照：Flux pull 式收敛 vs Cloudify 编排器 push + 关系数据流；两者独立做，互不依赖 |
| **devops.md 项目 22**（OPA/Conftest，⬜ 未做） | 项目 15 的 cfy-lint 只查蓝图写法；策略引擎（意图校验）仍是 OPA 的活，不重做 |
| **devops.md 项目 24**（SOPS 密钥，已完成） | 项目 11 的 Manager secrets store 是「运行时注入」，SOPS 是「文件加密」；边界写进项目 11 笔记 |
| **devops.md 项目 28**（漂移检测，⬜ 未做） | 项目 8 的 `refresh_terraform_resources` 与项目 12 的 heal 为漂移工具链再添两员 |
| **cicd.md 项目 1**（act 本地回路，已完成） | 项目 15 直接复用；workflow 语法不再教学 |
| **pulumi.md**（全线，已完成） | 三方对照：pulumi/01 ↔ 项目 7（Docker）、/03 secrets ↔ 项目 11、/05 组件 ↔ 项目 2 自定义类型、/09 K8s ↔ 项目 14、/11 多 Provider ↔ 项目 16、/12 CI ↔ 项目 15 |
| **hands-on-aws**（LocalStack 30 实验） | **不接**：Cloudify AWS 插件不在本清单（零云定位）；需要时另开进阶线 |
| **跳过项** | 多租户 / 用户 RBAC / LDAP / HA 集群（Premium 专属，社区版单用户单租户）、host agents（需 VM + SSH）、OpenStack/AWS/Azure/GCP 插件（零云）、Composer 可视化设计器深潜、Cloudify 云托管版、EaaS 多环境嵌套（`cloudify.nodes.Component`）——需要时另开进阶线 |

## 📚 网络与能力实测速查表（✅=2026-10-26 真机实测 / ⚠️=待开工验证 / ❌=实测不可用）

| 能力 | 涉及项目 | 实测结论 |
|:---|:---|:---|
| cfy 7.0.5 CLI | 全部 | ✅ Python 3.11 venv + `setuptools<81`；❌ Python 3.13（`cgi` 模块已移除，`ModuleNotFoundError`）；3.12 未测（理论可行，`cgi` 尚在但 deprecated） |
| 本地模式（零 Manager） | 1-9、15 | ✅ init → install → outputs → uninstall 全链路 + script 插件 + `ctx` CLI + `get_input`/`get_attribute` 真机通过；❌ `scale`/`heal` 本地报 `Implemented by subclasses`（Manager 专属） |
| `cfy blueprints validate` 无 Manager | 1、15 | ✅ 可用；坏 type 报 `path: node_templates.x.type` |
| types.yaml 获取 | 全部 | ❌ raw.githubusercontent.com / jsDelivr / ghfast / kkgithub 全部不可达；✅ `api.github.com` Contents API（`Accept: application/vnd.github.raw+json`，53KB 成功） |
| 插件源码与 wagon 下载 | 7-9、13、14 | ✅ `codeload.github.com`（tar.gz 200）/ `github.com` archive zip（-L 200）/ release assets（.wgn 803KB 成功） |
| 官方插件 pip 安装 | 7-9、14 | ✅ docker 2.0.16 `--no-deps` + 手补 docker/fabric/patchwork + SDK `--no-deps` 后 import 与真起容器全通；❌ 直装（`fusion-common` 不在 PyPI 也不在公开 GitHub） |
| 官方插件 wagon 平台 | 13 | ⚠️ 六个插件（utilities 2.0.6 / helm 0.4.11 / docker 2.0.16 / k8s 2.13.31 / terraform 0.21.6 / ansible 3.2.7）全部仅 `manylinux-py311-none-linux_x86_64`，无 aarch64 → 项目 13 的攻坚/fallback 由此而来 |
| AIO 社区镜像 | 10-13 | ✅ manifest 实测 7.0.1 / latest / 6.4.2 均含 linux/arm64 + amd64（arm64 压缩 1.63GB、amd64 0.83GB）；✅ `docker.1ms.run` 小层正常；❌ **≥360MB 大层经全部可用源断流**：1ms.run `short read`/`magic number mismatch`（arm64+amd64 各试两次）、`hub.rat.dev` `magic number mismatch`、`docker.1panel.live` manifest 403、守护进程自带 ustc/163/baidubce `short read`（362MB 层断在 6.8MB）→ Manager 启动 ⚠️ 待验证，开工走「换时段重试 / daemon 配代理直连 / 他机 docker save+load」三路之一 |
| cfy-lint | 15 | ✅ 0.0.37 在清华源可查 |
| 社区版功能边界 | 11 | ⚠️ 单用户单租户：多租户 / RBAC / LDAP / HA 为 Premium（官方文档确认）；快照属核心功能可用 |
| 项目活跃度 | 全部 | ⚠️ cli 最后提交 2024-08-01 / manager 2024-08-12 / common 2024-08-13；CLI 7.0.5 发版 2024-11-05；未归档（Dell 2023 收购） |
| 官方插件本地模式 | 8、9 | ❌ terraform 0.21.6：`LOCAL_REST_CERT_FILE` → 伪造证书后 `inet_pton(None)`，劫持 `REST_HOST` 则无限挂起；ansible 3.2.7：precreate `join(NoneType)`——均秒败（validate 可过）；docker 2.0.16 ✅ 本地可用（07 实测）。本地替代：script 插件包装本机工具（接口形状与官方对齐，上 Manager 可平移） |
| 自写插件本地执行 | 5、6 | ✅ `pip install -e` 进 CLI venv 即可，implementation 首段必须匹配 `plugins:` 声明名；无需 wagon |
| 本地任务并发 | 6 | ⚠️ `executions start --task-thread-pool-size` **默认 1（串行）**；图并发 = 无依赖任务（每实例一条 sequence）+ 池容量，二者同时成立才并行（实测 3.02s → 1.01s） |
| `cfy -p` 参数解析 | 8 | ⚠️ 整串先试 JSON（dict 参数用一个 JSON 对象包全部）；`key=value` 形式把 dict 值留成字符串；operation inputs 与 operation_kwargs 同名键冲突需 `allow_kwargs_override` |
| script 插件临时目录 | 8、9 | ⚠️ 只含被执行的脚本本身——蓝图目录其他文件不随行，外部文件主脚本 stage 到固定路径、经 inputs 传绝对路径 |
| registry.terraform.io | 8 | ⚠️ 2026-10-27 起本网络被 RST（labs/01 时可用）——filesystem_mirror 复用已下载 provider（按 darwin_arm64 目录布局） |
| AIO 镜像自救脚本 | 10 | ✅ `cloudify/scripts/fetch_manager_image.sh`：mirror token 流程 + 逐 blob 断点续传（Range 实测 307→CDN 可续）+ sha256 校验 + 组装 docker-archive + docker load；当前网络被 CDN 限速（~0.1MB/s）故未跑完，网络恢复/有代理即可执行 |
| 官方 k8s 插件本地模式 | 14 | ✅ 与 terraform/ansible 不同族——create/read 全可用；写路径（update_resource_definition 工作流 / delete）在新版 client+API server 组合下 422（min-availability），滚动更新走 kubectl + 插件 poststart 重读；依赖链见 14 README（kubernetes==26.1.0 必降级 + 两个 stub 包） |
| act 本地 CI | 15 | ✅ python:3.11-slim 镜像 + `--bind` + `--pull=false` 三件套；workspace 只带 git tracked 文件（untracked 必空）；容器装 cloudify 三道闸（break-system-packages / 钉 cloudify-common==7.0.5 / PIP_ONLY_BINARY pyyaml） |
| get_attribute 求值时机 | 16 | ⚠️ resource_config（模板属性）= plan 期（上游任务产物拿不到，实测空 dict）；operation inputs = 任务期（跨工具数据流唯一正道） |

## 📚 来源

- [Cloudify 7.0.0 文档——社区版下载](https://docs.cloudify.co/7.0.0/trial_getting_started/set_trial_manager/download_community)
- [Docker 安装 Manager（社区版）](https://docs.cloudify.co/6.4.0/cloudify_manager/community/install_and_configure/docker)
- [Docker Hub：community-cloudify-manager-aio](https://hub.docker.com/r/cloudifyplatform/community-cloudify-manager-aio)
- [多租户为 Premium 功能（5.1 文档）](https://docs.cloudify.co/5.1/working_with/manager/implement-multi-tenancy)、[授权模型（7.0）](https://docs.cloudify.co/7.0.0/cloudify_manager/architecture/security/authorization)
- [快照（6.4 文档）](https://docs.cloudify.co/6.4.0/working_with/manager/snapshots)
- GitHub（cloudify-cosmo）：cloudify-cli / cloudify-manager / cloudify-common / cloudify-docker-plugin / cloudify-kubernetes-plugin / cloudify-terraform-plugin / cloudify-ansible-plugin；（cloudify-incubator）：cloudify-utilities-plugin / cloudify-helm-plugin
- PyPI：cloudify 7.0.5 / cloudify-utilities-plugins-sdk 0.0.130 / cfy-lint 0.0.37（清华源）
- 蓝图范例库：[cloudify-community/blueprint-examples](https://github.com/cloudify-community/blueprint-examples)

> 动手实验统一放 `cloudify/NN_short_name/`，编号与本清单项目号 1:1 对应；结构沿用 pulumi/ 与 labs/ 约定（README 教程 + 主脚本 + 蓝图 + vendor/）。
