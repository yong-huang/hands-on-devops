# 09 · ⛓️ Ansible 插件：docker 容器 × ansible 配置 × 幂等重跑

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 9 · 阶段二收官集成点
> docker 插件起容器 → connected_to 的 establish 钩子生成 inventory 并跑 `ansible-playbook`（community.docker 连接）→ execute_operation 重跑证明幂等；官方 ansible 插件负向留证

## Background

三个工具各就其位：**docker 插件**负责「资源存在」（起容器），**ansible** 负责「配置到位」（容器内文件），**Cloudify 关系**负责「顺序与数据流」（容器 ID 从 target 流向配置操作）。这就是「编排器之上的编排器」的完整形状——与 labs/06（独立跑 role）的差异：role 在这里被关系钩子调度，拿到的是**运行时**的容器身份，而不是写死的 inventory。

## What

- `bp.yaml`：`app`（docker 插件起 `python:3.12-slim`，自带 python3，`sleep infinity`）+ `configure`（自定义类型 `handson.nodes.Configurator`，`connected_to app`）
- `scripts/ansible_configure.py`（establish + maintenance.reconfigure 双钩子）：写 inventory（`ansible_connection: community.docker.docker`，host=容器长 ID）→ `ansible-playbook` → recap 解析 → `ansible_changed` 写 runtime properties
- `playbooks/site.yaml`：copy + lineinfile 两个幂等模块（写 `/etc/motd` 与 profile 标记）
- `bp_official.yaml`：官方 `cloudify-ansible-plugin 3.2.7` 负向用例（validate 过 / install 在 precreate 秒败）

## When to Use

- 资源编排（容器/VM）与配置管理（playbook）分属两套工具，但交付要一个按钮 → 编排器的关系钩子做粘合
- 幂等验证是配置管理的出厂设置：首次 `changed>0`、重跑 `changed=0` 应作为部署测试的标配断言

## Quick Start

```bash
./ansible_plugin.sh    # 4 相 12 断言：official-neg / install / idempotent / uninstall
```

前置：本机 ansible-core + `community.docker` collection（`ansible-galaxy collection list | grep docker`）；docker 插件依赖同实验 07。

## How It Works

### 双上下文的同一个脚本

establish 在**关系上下文**跑（`ctx.source`/`ctx.target` 可用）；execute_operation 重跑在**节点上下文**（没有 target，`ctx.node`/`ctx.instance` 才可用——两种上下文的 API 互斥，访问错的对象直接抛错）。脚本用 `_context_views()` 自适应：关系上下文从 target 拿容器 ID；节点上下文从自身 runtime properties 回读上次记录的 `target_container`。**首次配置必须把外部资源身份写进自己的 runtime properties**——这是 Day-2 重操作能脱离关系独立重跑的前提。

### 行序与幂等的证据链

- install 日志行号：`[app_*] Node instance created`（行 9）早于 `ansible inventory written`（行 25）——关系保证的顺序
- 首次 recap `changed=2` → `ansible_changed=yes`；重跑 `changed=0` → `no`；两次之间 `docker exec cat /etc/motd` 内容不变

## Pitfalls & Q&A

1. **官方 ansible 插件本地秒败**（与 08 的 terraform 插件同族）：`cloudify_ansible.tasks.precreate` → `join() argument must be str ... not 'NoneType'`——Manager 文件系统路径在本地不存在。负向留证，本地用 script 包装。
2. **上下文类型互斥**：关系上下文访问 `ctx.node`/`ctx.instance`、节点上下文访问 `ctx.source`/`ctx.target` 都直接抛错。写"关系+可重跑"双钩子脚本时先分派上下文。
3. **`cloudify.nodes.Root` 不接受自定义 properties**（dsl_1_5 严格 schema 校验：`'stage_dir' property is not part of the derived type properties schema`）——要挂属性就定义自定义 node_types。
4. **容器要有 python3**：`ansible_connection: docker` 需要容器内 python；`nginx:*-alpine` 没有，选 `python:3.12-slim`（本机已有镜像，零下载）。
5. **playbook/inventory 要 stage 到蓝图外的固定路径**：script 插件的临时目录只含被执行的脚本本身（实测），蓝图目录里的其他文件不会跟着进容器外脚本的工作目录。
6. configure 的 create 钩子别顺手挂配置脚本——node 上下文没有 target，install 必炸；配置动作只挂 establish + maintenance。

## 产物清单

- `bp.yaml`（docker 容器 + Configurator + establish）+ `scripts/ansible_configure.py` + `playbooks/site.yaml` + `bp_official.yaml`（负向）
- `ansible_plugin.sh`：4 相 12 断言全绿
