# 05 · 自写 Python 插件：plugin.yaml、@operation 与 MockCloudifyContext 单测

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 5 · 阶段二「插件与编排器之上的编排器」
> 手写一个 Cloudify 插件包（HttpCheck 轮询探活 + RenderedFile 模板落盘），pytest 单测 + 本地模式真机执行

## Background

script 插件（实验 01-04）适合胶水逻辑；真正的插件是 **Python 包**：`@operation` 装饰的函数拿 `ctx` 对象操作属性/实例/重试，`plugin.yaml` 声明插件名与自定义节点类型。写插件的动机是复用与可测性——探活、轮询、渲染这类逻辑值得有 pytest 而不是散落的 bash。本地模式对插件相当友好：CLI venv 里 `pip install -e` 后，本地引擎执行时直接 `import` 你的模块，**不需要 Manager、不需要打包 wagon**（wagon 是项目 13 上 Manager 的事）。

## What

- `plugin/`：setup.py + `handson_plugin/tasks.py`（4 个 @operation）+ plugin.yaml（`plugins:` 段 + 2 个自定义 node_types）
- `check_http`：轮询 URL 直到期望状态码；内部轮询用尽后 `raise OperationRetry` → 引擎按操作级 `max_retries: 3` 重试
- `render_file` / `remove_file`：生命周期对称的落盘/清理（uninstall 时 delete 钩子真删文件）
- pytest：`MockCloudifyContext` 四条路径——成功写 runtime property / 503→OperationRetry→200 / 渲染与路径记录 / 缺属性抛 `NonRecoverableError`
- 负向事实留证：`dsl_1_5` **不校验属性值类型**（`url: 28185` integer 填 string 属性照样 validate 通过）；解析期真正的闸门是 required 缺失

## When to Use

- 逻辑要被多个蓝图复用、需要单测、需要结构化 ctx 操作 → 插件；一次性胶水 → script 插件
- 交互重试：可重试的临时故障 `raise OperationRetry`（等价 `ctx.operation.retry(msg)`，但后者在 mock 上下文不抛异常、不可测）；业务性不可恢复 → `NonRecoverableError`

## Quick Start

```bash
# 一次性（脚本会自己做）：uv pip install -e ./plugin pytest（装进 cloudify/.venv）
./my_plugin.sh    # 5 相 14 断言：test / validate / install / outputs / uninstall
```

## How It Works

### 本地引擎怎么找到你的插件

蓝图 imports vendor 的 `plugin.yaml`（含 `plugins: handson: package_name: handson-plugin`），操作引用写成 **`<插件名>.<模块路径>.<函数>`**：`handson.handson_plugin.tasks.check_http`——首段必须匹配 `plugins:` 里声明的名字，解析器据此识别「这是插件操作」并省略脚本资源检查；本地执行时引擎在 venv 里 `import handson_plugin.tasks`。对照官方写法 `docker.docker_plugin.tasks.create_container` 同构。

### plugin.yaml = plugins 段 + node_types 段

```yaml
plugins:
  handson:
    executor: central_deployment_agent
    package_name: handson-plugin
    package_version: 0.1.0
node_types:
  handson.nodes.HttpCheck:
    derived_from: cloudify.nodes.Root
    properties: { url: {type: string}, expect_status: {type: integer, default: 200}, ... }
    interfaces:
      cloudify.interfaces.lifecycle:
        create:
          implementation: handson.handson_plugin.tasks.check_http
          max_retries: 3        # dsl_1_5：操作同级键（实验 04 结论），重试预算
          retry_interval: 2
```

### 单测的三件套

`MockCloudifyContext(node_id=..., node_name=..., properties=..., operation={"retry_number": 0})` + `current_ctx.set(ctx)`；外部依赖 `mock.patch.object(tasks.requests, "get", side_effect=[FakeResponse(503), ...])`；测**内层函数** `_check_http`——`@operation` 装饰的函数脱离引擎直调会吞掉 OperationRetry。

## Pitfalls & Q&A

1. **implementation 首段必须等于 plugins: 里声明的插件名**，否则 validate 报 `Could not extract plugin or a script resource is not found from operation mapping/script-path ...`。
2. **MockCloudifyContext 必须给 `node_id`**——只给 node_name 得到 deployment 上下文，`ctx.node/ctx.instance` 报 `can only be used in a node-instance context`。
3. **`ctx.operation.retry()` 在 mock 里不抛异常**（真引擎才抛）；插件里用 `raise OperationRetry(msg)`，语义相同且可测。
4. **`mock.patch(side_effect=单个响应对象)` 会报 `'FakeResponse' object is not an iterator`**——side_effect 要么是可调用/异常，要么是「返回值列表」。
5. **dsl_1_5 不校验属性值类型**（实测负向留证）；required 缺失有干净报错：`'check' node does not provide a value for mandatory 'url' property`。想要类型闸门，用约束（实验 02）或插件运行时自检。
6. `$PORT` 后紧跟全角括号再次踩了变量名吞字节坑——脚本已统一 `${var}`。

## 产物清单

- `plugin/`（setup.py + handson_plugin/tasks.py + plugin.yaml + tests/test_tasks.py）+ `bp.yaml` / `bad.yaml`
- `my_plugin.sh`：5 相 14 断言全绿；vendor/plugin.yaml 为蓝图侧 import 的拷贝（与 plugin/ 内同源）
