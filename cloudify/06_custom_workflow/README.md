# 06 · 自定义工作流：@workflow 任务图、批次滚动与执行并发度

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 6 · 阶段二「插件与编排器之上的编排器」
> 插件包里写 `@workflow rolling_restart`（批次子图 + 链式依赖），实测串行/并发两种执行形态与参数校验边界

## Background

`install/uninstall/execute_operation` 是内建工作流（实验 04 用过 execute_operation）；业务要的往往是**自己的** Day-2 编排——比如「每批 N 个实例滚动重启」。工作流也是插件代码：`@workflow` 函数拿工作流 ctx（`ctx.node_instances`），用**任务图**声明谁等谁，引擎按图调度。与 TF/Pulumi 的差异：它们没有「对活部署的第二段编排」这个概念，这是 TOSCA 编排器的立身之本。

## What

- `handson_flow` 插件：`restart` 操作（固定 1s 假负载，时间戳写入 runtime properties）+ `rolling_restart` 工作流（batch 参数 → 批次子图链）
- 蓝图 `workflows:` 段 mapping 到插件函数；3 实例 Service
- 三相实测：batch=1 串行（3 批次、总时长 3.02s）；batch=3 + `--task-thread-pool-size 3` 并发（1 批、总时长 1.01s、三个 1s 重启重叠）；batch=-1 被工作流自检拒绝

## When to Use

- 多实例的滚动/分批操作（重启、升级、批量备份）→ 批次子图 + `graph.add_dependency` 链式批间依赖
- 内建 execute_operation 表达不了的控制流（分批、条件、扇出聚合）→ 自写 @workflow

## Quick Start

```bash
./custom_workflow.sh    # 5 相 11 断言：install / serial / parallel / bad-batch / 收尾
```

## How It Works

### 任务图的三种构件

```python
@workflow(resumable=True)
def rolling_restart(ctx, batch, **kwargs):
    graph = ctx.graph_mode()                      # 1) 图
    subgraph = graph.subgraph("batch-0")          # 2) 批次子图
    for instance in chunk:
        sequence = subgraph.sequence()            # 3) 每实例一条序列（内部串行）
        sequence.add(instance.send_event(...),
                    instance.execute_operation("handsonflow.interfaces.lifecycle.restart"),
                    instance.send_event(...))
    graph.add_dependency(subgraph_b, subgraph_a)  # 批间链式依赖
    graph.execute()
```

**每实例一条 sequence 是关键**：sequence 内部任务串行；不同 sequence 之间无依赖 → 引擎把就绪任务并发派发。第一版把三个实例塞进同一条 sequence，batch=3 也串行——图的并发单位是「无依赖任务」，不是「同批」。

### 并发度是执行配置，不是蓝图属性

本地引擎的任务由线程池执行：`cfy executions start ... --task-thread-pool-size N`（**默认 1**，所以什么都不配就是串行）。实测 batch=3：默认池 3.02s 逐个跑；池=3 时 1.01s 三个 1s 重启重叠。Manager 端同理（mgmtworker 线程池），语义一致。

### 参数校验的边界（实测）

蓝图的 `parameters.constraints: [greater_than: 0]` **本地引擎不校验**——`-p batch=-1` 照常启动。工程化解法在工作流入口自检（`raise RuntimeError` → 执行失败、消息进日志），断言两个证据：execution failed + 自检消息。

## Pitfalls & Q&A

1. **sequence 是串行链**：想并发就别把实例塞进同一条 sequence；「图并发 = 无依赖任务」+「线程池大小」两个条件都成立才看得见并行。
2. **`--task-thread-pool-size` 默认 1**（`cloudify_cli/cli/cfy.py` 里 option 定义的 default=1，与引擎常量 8 无关）——不显式给就是串行，别误判为「本地引擎不支持并发」。
3. **`ctx.node_instances` 无序**：分批前 `sorted(by id)`，让批次划分确定、断言可复现。
4. **工作流里操作引用**：`instance.execute_operation` 的操作名写全 `<接口>.<操作>`，接口在 node_types 里声明过（`handsonflow.interfaces.lifecycle.restart`）。
5. 工作流函数签名 `def rolling_restart(ctx, batch, **kwargs)`——蓝图 parameters 与 `-p` 传参按名对齐；`@workflow(resumable=True)` 与操作装饰器同源。

## 产物清单

- `plugin/`（handson_flow: tasks.py + workflows.py + plugin.yaml）+ `bp.yaml`（3 实例 + workflows mapping）
- `custom_workflow.sh`：5 相 11 断言全绿；时长断言从日志首尾时间戳计算（`span_seconds`）
