# 02 · 节点类型与内建函数：自定义类型、输入约束与 get_property / get_attribute

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 2 · 阶段一「TOSCA 建模与本地执行」
> 自定义 `node_types` + `data_types`、四类输入约束、三个内建函数、同一键的静态/运行期双面观、类型默认值演化

## Background

实验 01 直接用 `cloudify.nodes.Root` 当节点类型——那是「什么都不带」的基类。真实蓝图要定义**自己的类型**：属性 schema（名称/类型/默认值）挂在 `node_types`，复合结构挂在 `data_types`，非法输入靠 `inputs.constraints` 在解析期挡下。这一层是 TOSCA 与 Terraform `variable validation`、Pulumi config 类型的对照面：TOSCA 把「类型 + 默认 + 约束」定义在**类型上**而不是用例上，实例（node_templates）只声明覆盖项。

## What

- `handson.nodes.Worker`（自定义 node_types）：两个属性——标量 `worker_name` 与 data_type 复合属性 `config`
- `handson.types.WorkerConfig`（data_types）：`name` / `workers` 各带默认值
- 三条约束输入：`in_range`（端口）、`valid_values`（环境）、`pattern`+`min_length`（团队名）
- 同键双面观：脚本覆写 runtime property 后，`get_property`（解析期静态）与 `get_attribute`（运行期值）在 outputs 里并排出现
- 内建函数三件套：`concat` / `string_upper` / `string_replace`（后者是**位置参数列表**，`str.replace` 语义）
- 演化断言：改 node_type 的默认 `workers` 2→5，两个实例的输出同步变化

## When to Use

- 想约束「这套蓝图里某类节点的必填/可选属性」时——写 node_type，而不是在每个 template 里重复 schema
- 想在 `cfy init -i` / Manager 表单层就挡掉非法参数时——用 constraints；它在解析期报错，比部署后失败便宜一个数量级

## Quick Start

```bash
./types_functions.sh        # 全部 6 相 19 断言（validate/constraints/install/outputs/evolution/收尾）
./types_functions.sh outputs   # 单相重跑
```

## How It Works

### 解析期 vs 运行期：同名键的两张面孔

`alpha_worker_name` 在解析期是 `alpha-worker`（get_property 从节点属性读）；`scripts/create.py` 运行时用 `ctx.instance.runtime_properties['worker_name'] = 'runtime-<instance-id>'` 覆写同名键；outputs 并排输出两个函数的读值——`get_property` 仍是旧值，`get_attribute` 是新值。**不要在脚本里试图改 node properties**，那是解析期产物。

### 类型默认值的合并规则（本实验的演化设计）

实例**整体省略** `config` 属性 → 吃 data_type 默认 `{name: default-worker, workers: 2}`；`sed` 把类型默认的 `default: 2` 改成 5 后重装，alpha/beta 的 `beta_workers` 与 `alpha_workers_runtime` 都变 5。alpha 只覆盖了标量 `worker_name`，不受影响——「实例级覆盖优先于类型默认」的最小演示。注意：**部分 dict 会不会与默认深合并，本实验未验证**，两实例都整体省略 config 就是为了不依赖该行为。

### 约束报错的三种形态（实测原文）

| 用例 | 报错 |
|:---|:---|
| `-i env=bogus` | `Value bogus of input env violates constraint valid_values(dev, staging, prod) operator.` |
| `-i team=Platform` | `Value Platform of input team violates constraint pattern(^[a-z]+$) operator.` |
| `-i port=70000`（整数 input 的 in_range） | `Value is not comparable, the Constraint argument type is 'list' but value type is 'str'.` |

第三条是上游怪癖：CLI 的 `-i` 恒传字符串，整数 input 的 in_range 在类型转换前比较，报出误导性类型错误——**但确实拒绝**（退出码非 0）。想要干净报错，约束尽量放 string 型输入。

## Pitfalls & Q&A

1. **`string_replace` 是位置参数列表**：`string_replace: [haystack, needle, replacement]`，写成 dict 报 `should be called with three or four parameters`（needle 是字面量非正则，见 dsl_parser/functions.py `StringReplace.parse_args`）。
2. **失败的 init 会留半初始化上下文**：约束拒绝后紧接着再 `init -b 同名` 报 `[Errno 2] ... deployments/types`。每条负向用例先重置 workdir（脚本已这么办）。
3. **改类型默认值的 sed 要锚定**：YAML 里 `workers:` 与 `default: 2` 是两行，直接 sed `workers: 2` 不会命中；脚本用 `s/^        default: 2$/.../`。
4. **trap 还原别提前删备份**：`rm -f .bp.yaml.bak` 放在阶段末尾会让 trap 无物可还原，中断/失败后源文件停在改写态。备份只在 EXIT trap 里消费（`mv` 自删）。对未跟踪文件 `git status` 恒 `??`，**验不了内容还原**——断言要写在脚本里而不是靠 git 目检。
5. **收尾 uninstall 别 reset workdir**：reset 会连蓝图上下文一起删掉，随后 `executions start` 报 `Please initialize a blueprint`。
6. **outputs 是扁平 JSON**：`deployments outputs` 输出 `{"key": value}`（值不包 `{value: ...}` 壳），可直接 grep 精确断言；含随机实例后缀的值（`runtime-alpha_<6位>`）用 `grep -E` 模式。

## 产物清单

- `bp.yaml`（node_types/data_types/三约束输入/8 输出）+ `scripts/create.py`（python 版 script 插件，ctx API 读属性）
- `types_functions.sh`：6 相 19 断言全绿；`.logs/` 留档
