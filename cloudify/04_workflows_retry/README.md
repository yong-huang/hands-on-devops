# 04 · 工作流与容错：execute_operation、重试预算与 abort

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 4 · 阶段一「TOSCA 建模与本地执行」
> 三份蓝图各证一件事：重试后成功 / 重试耗尽 / abort 绝不重试；外加 execute_operation 调自定义接口

## Background

实验 01-03 的 install/uninstall 是内建工作流。这一层往下挖两件事：**容错语义**（任务失败后引擎怎么办）和**自定义工作流入口**（不装插件包也能对运行中的部署执行 Day-2 操作）。与 Terraform/Pulumi 的关键差异：TF/Pulumi 没有部署级工作流概念——出问题只能整把重新 apply/up；Cloudify 的 execute_operation 能对「活着的部署」按节点/实例圈定范围执行任意操作。

## What

- **bp.yaml**：`handson.nodes.Flaky`（计数文件制造确定性故障：前 2 次失败、第 3 次成功，operation 级 `max_retries: 3` + `retry_interval: 1`）+ `handson.nodes.Data`×2 带**自定义接口** `handson.interfaces.maintenance.backup`
- **bp_exhaust.yaml**：同一 flaky 脚本配 `max_retries: 1` → 恰好执行 2 次后失败；`uninstall -p ignore_failure=true` 清理失败安装
- **bp_fatal.yaml**：`ctx.abort_operation` → 恰好 1 次执行、零重试、立即失败
- **execute_operation**：`cfy executions start execute_operation -b wf -p operation=handson.interfaces.maintenance.backup` → data×2 各执行一次

## When to Use

- 会闪断的外部依赖（下载、探活、锁竞争）→ operation 级 max_retries，让引擎代劳「失败-等待-重试」
- 业务级不可恢复错误（参数非法、凭据被拒）→ 脚本里 `ctx.abort_operation`，别浪费重试预算
- 已安装部署的 Day-2 动作（备份、刷新、reload）→ 自定义接口 + execute_operation；**scale/heal 不在此列**——本地模式报 `Implemented by subclasses`（Manager 专属），见清单项目 12

## Quick Start

```bash
./workflows_retry.sh    # 5 相 16 断言：validate / retry-success / execute-op / exhaust / fatal
./workflows_retry.sh exhaust   # 单相重跑（重置 workdir + 计数文件，幂等）
```

## How It Works

### 重试的三层证据（日志原文）

```
Task started 'script_runner.tasks.run'                    ← 第 1 次
Task failed  'script_runner.tasks.run' -> 1 [retry 1/3]   ← 失败，进入第 1 次重试
Task started 'script_runner.tasks.run' [retry 1/3]        ← 重试执行（间隔 retry_interval）
Task succeeded 'script_runner.tasks.run' [retry 2/3]      ← 第 3 次执行成功
```

计数文件（`/tmp/handson04-flaky.count`）让失败次数与执行次数一一对应，断言因此可精确到「执行 N 次」。`attempts` runtime property 是脚本侧的独立账本，与日志交叉验证。

### dsl_1_5 的重试参数位置（易错点）

`max_retries` / `retry_interval` 是操作的**同级键**（与 `implementation`/`inputs` 平级），不是 operation inputs，且只收**裸数字**（不支持 `get_input`）：

```yaml
create:
  implementation: scripts/flaky.py
  max_retries: 3          # ✅ 同级键
  retry_interval: 1
  inputs: {}              # 这里才是真正的任务输入
```

写进 `inputs:` 报 `Expected 'dict' type but found 'integer' type`。

## Pitfalls & Q&A

1. **abort 与 retry 的分界**：脚本非零退出/抛异常 → 按预算重试；`ctx.abort_operation(msg)` → 抛出终止异常，整个执行立即 failed、零重试。消息原文进执行日志（`Task failed ... -> fatal: unrecoverable condition detected`）。
2. **失败安装的清理**：install 失败后实例可能停在半建状态，普通 uninstall 可能被卡住的实例挡住——`-p ignore_failure=true` 让清理忽略单点失败继续走完（本实验已实测清零）。
3. **execute_operation 的 operation 参数格式**：`<interface>.<operation>` 全名（如 `handson.interfaces.maintenance.backup`），不带节点名——它对**所有实现了该接口的实例**各执行一次（data×2 → 2 次任务）。
4. **Bash 工具/交互 shell 的 cwd 陷阱**（开发过程真踩）：相对路径 `../.venv/bin/cfy bp.yaml` 在错误目录执行，会把**另一个实验的蓝图**存进本实验的部署 ID（实测：rel 蓝图被存成 wf）。每次探针/脚本开头都显式 `cd "$(dirname "$0")"` 或绝对路径。
5. **多实例 + 属性断言**：data×2 中只有 flaky 有 `attempts`——查询助手按实例打值时会输出空行，`inst_attr` 已统一滤空；数实例数用 `| grep -c .`。

## 产物清单

- `bp.yaml` / `bp_exhaust.yaml` / `bp_fatal.yaml` + `scripts/{flaky,fatal,data_create,backup}.py`
- `workflows_retry.sh`：5 相 16 断言全绿；`.logs/` 留档
