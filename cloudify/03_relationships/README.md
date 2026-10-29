# 03 · 关系与生命周期：connected_to / contained_in 与跨节点数据流

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 3 · 阶段一「TOSCA 建模与本地执行」
> 8 实例一张图：db ←(connected_to) app，host×3 ←(contained_in) worker×3；establish 钩子跨节点传值；安装/卸载顺序全程断言

## Background

实验 01/02 的节点互相独立——装一个应用真正要的是「**先有数据库，再起应用，应用拿到数据库地址**」。TOSCA 用关系（relationships）表达这件事，而且关系不只是顺序：它是**带生命周期的通道**，两侧都能挂操作、都能拿到对方上下文。这是与 Terraform（`depends_on` 只管顺序、引用只在配置期）最大的体验差异：TOSCA 的关系在 install/uninstall 各阶段都会执行钩子，且钩子里能同时读到 source 与 target 的运行期属性。

## What

- `connected_to` + `source_interfaces`：app 的 establish 钩子用 `ctx.target.instance.runtime_properties` 读 db 写入的 ip/port，写进自己的 `db_endpoint`（跨节点数据流）
- `contained_in` + `instances.deploy: 3`：host 3 实例、每个 host 携带一个 worker → worker 自动 3 实例（实例数相乘）
- 安装顺序断言：db `Node instance started` 早于 app 的 create 任务；卸载严格逆序（app 先于 db 删除）
- 多实例证据：`worker_`/`host_` 活跃实例计数 = 3（直读本地存储，CLI 查询面不覆盖）

## When to Use

- 组件间有「数据要从 A 流到 B」的关系（地址、端口、生成的凭据）→ connected_to + establish
- 组件有「宿主-寄居」语义（agent 装进 VM、容器进 Pod 网络）→ contained_in，实例数由宿主 deploy 数相乘
- 只要先后顺序不要数据 → `depends_on`（本实验未单列，行为是 connected_to 的子集）

## Quick Start

```bash
./relationships.sh    # 5 相 14 断言：validate / install / order / outputs / uninstall
```

## How It Works

### establish 钩子的两侧上下文

`scripts/establish.py` 运行时同时持有 `ctx.source`（app 实例）与 `ctx.target`（db 实例）——日志行 `[app_8uy2kd->db_phx20o|establish]` 直接标出这条有向边。钩子的声明在**关系条目**上：

```yaml
relationships:
  - type: cloudify.relationships.connected_to
    target: db
    source_interfaces:            # dsl_1_5 语法（老教程的 source_operations 会报 not in schema）
      cloudify.interfaces.relationship_lifecycle:
        establish:
          implementation: scripts/establish.py
```

install 顺序由关系推导的 DAG 决定：db create → establish（preconfigure/establish/postconfigure）→ app create；uninstall 严格逆序。日志证据：`Subgraph started 'cloudify.interfaces.relationship_lifecycle.establish_subgraph'`。

### 实例数相乘与存储计数

`host` 声明 `instances: deploy: 3`，worker `contained_in host` → worker 自动 3 实例（本地存储 `worker_*.json` 数出 3）。**多实例节点的 `get_attribute` 本地模式报错**（`More than one node instance found ... Cannot resolve a node instance unambiguously`，带索引 `[host, attr, 0]` 同样不支持）——所以本实验的 outputs 只断言单实例的 `db_endpoint`，多实例证据一律走 `../scripts/local_query.py` 计数与读 runtime properties。

## Pitfalls & Q&A

1. **dsl_1_5 关系钩子键是 `source_interfaces`**，不是老教程（1_3 时代）的 `source_operations`——后者报 `'source_operations' is not in schema. Valid schema values: ['type', 'target', 'properties', 'source_interfaces', 'target_interfaces']`。报错本身很友好，会列出合法键。
2. **多实例 get_attribute 无列表、无索引消歧**：想拿某个实例的值，要么让脚本把值写进单实例节点的 runtime property，要么直读存储 JSON。
3. **bash 里 `$var` 后紧跟全角字符会吞坏变量名**：`"...行 $db_start）"` 在 C locale 下 bash 把 `）` 的首字节并进变量名 → `db_start\ufffd: unbound variable`。规则：`$var` 后只要不是 ASCII 边界就写 `${var}`（四个实验脚本已统一）。
4. **首个删除实例不固定**：app 链（app→db）与 worker 链（worker×3→host×3）互相独立，谁先删取决于并发时序；可断言的是「app<db」「containee 先于自己的 container」「首个删除者必是 worker/app 之一」——别把整条删除序列写成逐行断言。

## 产物清单

- `bp.yaml`（3 个 node_types + connected_to/contained_in + establish 钩子）+ `scripts/{db_create,app_create,host_create,establish}.py`
- `relationships.sh`：5 相 14 断言全绿；`.logs/` 留档
