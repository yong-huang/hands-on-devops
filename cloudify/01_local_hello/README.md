# 01 · Cloudify 第一个蓝图：本地模式、script 插件与 ctx

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 1 · 阶段一「TOSCA 建模与本地执行」
> 一个节点的完整回路：`cfy init → install → outputs → uninstall`，零 Manager，全部断言在 `local_hello.sh`

## Background

[Cloudify](https://github.com/cloudify-cosmo) 是一个 TOSCA 编排器：你用 YAML 描述「应用由哪些节点组成、节点间什么关系、生命周期各阶段做什么」，它负责推导安装顺序、执行生命周期操作、支持 Day-2 工作流（scale/heal/update）。它与 Terraform/Pulumi 的差异在清单和后续实验逐条对照，本实验只回答一个问题：**不装 Manager，能不能跑通一个蓝图？** 答案是能——`cfy` CLI 内置了本地执行引擎（本地存储 + 本地工作流 + script 插件），这也是后续所有蓝图开发和 CI 冒烟的地基。

## What

- 一份最小蓝图 `bp.yaml`：`cloudify_dsl_1_5`、vendor 的 `types.yaml`、一个 `cloudify.nodes.Root` 节点、inputs/outputs
- script 插件：`implementation: scripts/create.sh`，operation inputs 以**环境变量**注入 bash，脚本里用 `ctx` CLI 写日志和 runtime property
- 四个断言面：`blueprints validate`（好/坏两份）、install 日志（ctx logger 输出）、`deployments outputs`（get_attribute 读回）、本地存储实例状态（uninstall 后零活跃实例）
- 幂等：全新 workdir 连装两遍，outputs 逐字节一致

## When to Use

- **本地模式（本实验）**：开发调试蓝图、单元级验证生命周期逻辑、CI 里的冒烟测试——不需要 Manager，秒级起停
- **Manager（阶段三）**：需要 REST/控制台、secrets、scale/heal、插件 wagon、多部署治理时才必须——本地模式跑不了它们（`scale`/`heal` 实测报 `Implemented by subclasses`）

## Quick Start

```bash
# 0) 一次性环境（仓库级，见 docs/cloudify.md 环境配置）
cd cloudify && uv venv --python 3.11 .venv
uv pip install --python .venv/bin/python cloudify==7.0.5 "setuptools<81"
# 1) vendor types.yaml（已由 _vendor/types.yaml 拷入本实验，刷新方式）：
#    api.github.com Contents API（raw.githubusercontent.com 不可达，见 Pitfalls）
# 2) 跑全部断言（CFY_WORKDIR 默认 ~/.cfy-handson/01_local_hello，在蓝图目录之外）
./local_hello.sh            # 或分相：validate / install / outputs / uninstall / idempotence
```

预期输出：11 个 ✅、`✅ 01 全部通过`，全程 < 30 秒。

## How It Works

### 蓝图解剖（bp.yaml 逐段）

- `tosca_definitions_version: cloudify_dsl_1_5`——7.0.x 的 `types.yaml` 用了 DSL 1.5 才有的 `operation_name` 参数类型，声明 1_4 解析直接失败
- `imports: vendor/types.yaml`——本地模式必须相对路径 vendor；`cloudify/types/types.yaml` 短路径是 Manager 端写法（Manager 把它重写到自己的文件服务器）
- `inputs` / `node_templates.hello.interfaces...create.inputs.who: { get_input: greeting }`——解析期把 input 值注入操作输入
- `outputs.msg: { get_attribute: [hello, said] }`——**运行期**读实例的 runtime property（`get_property` 是解析期读静态属性，实验 02 对照）

### 本地 install 的工作流机制

`cfy init` 把蓝图目录拷进 `CFY_WORKDIR/.cloudify/profiles/local/blueprints/app/resources/` 并解析成 plan；`executions start install` 用内置工作流引擎按 DAG 执行：`Creating node instance → Task started 'script_runner.tasks.run'（脚本落盘到临时目录执行）→ Node instance created/started`。状态是**文件式存储**：`deployments/app/node-instances/<id>.json`，每个实例一个文件，卸载后文件保留但 `state: "deleted"`。

### 查询面：CLI 本地模式只暴露一半

| 命令 | 本地模式 |
|:---|:---|
| `deployments outputs -b` / `executions list -b` | ✅ 可用 |
| `node-instances` / `nodes list` / `events list` | ❌（报 "Could not find node list" / "only available when using a manager"） |

实例级断言因此直读存储：`../scripts/local_query.py "$CFY_WORKDIR" app --alive`（`state != deleted` 计数）、`--attr said` 逐实例取 runtime property。uninstall 后 `outputs` 仍返回旧值——它是 install 时缓存的快照，不是活查询。

## Pitfalls & Q&A

1. **蓝图 YAML 只接受 ASCII**——描述里写中文（或 → 等符号）报 `illegal characters in line: 11. Only valid ascii chars are supported`。中文说明全部放 README，YAML 注释用英文。
2. **cfy 必须 Python 3.11**：3.13 报 `No module named 'cgi'`（3.13 移除了该模块）；uv venv 默认不带 setuptools，补 `"setuptools<81"` 否则 `pkg_resources` 缺失。启动时的 `pkg_resources is deprecated` 警告无害。
3. **`CFY_WORKDIR` 不能在蓝图目录内**——`init` 会把蓝图目录整目录递归拷贝进 workdir，workdir 在里面就无限自嵌套，报 `File name too long`。
4. **runtime property 的写入语法**：`ctx instance runtime-properties <key> <value>`（bash）；读取走蓝图的 `get_attribute` 或本实验的存储查询。
5. **日志里的 `line buffering ... RuntimeWarning`** 来自 cloudify-common 调 subprocess 的老写法，无害，断言不受影响。
6. **zsh 交互探命令**时 `cfy "$cmd"` 不会拆词（zsh 默认不做单词拆分），全部参数会被当一个词——交互探试用 `${=cmd}` 或干脆写进脚本。

## 产物清单

- `bp.yaml` / `bad.yaml`（负向）+ `scripts/create.sh` + `vendor/types.yaml`
- `local_hello.sh`：5 相 11 断言，`all` 全绿；日志在 `.logs/`（已 gitignore）
- 共享件：`../env.sh`（CLI/工作区/查询助手）、`../scripts/local_query.py`（本地存储查询）
