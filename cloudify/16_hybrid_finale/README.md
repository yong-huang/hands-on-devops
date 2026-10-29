# 16 · 🏁 混合编排终局：一个蓝图跨 Terraform / Docker / Ansible / Kubernetes

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 16 · 阶段四收官
> 五世界同图（全本地模式）：TF 底座 → docker 插件 web → establish 里 ansible → 自写插件探活 → k8s 插件并行分支；Day-2 用 06 的 rolling_restart

## Background

阶段二到四的全部能力在这张图上合体：**Terraform**（script 包装）管底座（私有网络 + api 容器）、**docker 插件**管 web 容器、**关系 establish** 里 **ansible** 配置容器、**自写插件 HttpCheck** 端到端探活、**kubernetes 插件**在 kind 上跑 ConfigMap+Deployment+Service 并行分支、**rolling_restart** 工作流做 Day-2。这就是「编排器之上的编排器」的完整形态——每个工具只做它最擅长的一段，蓝图负责把它们的顺序、依赖和数据流串起来。

## What

- `tf_module/`：docker_network `cfy16-net` + api 容器（outputs：network_name）
- `bp.yaml` 五分支 + 两个自定义类型（TfBase / Configurator）+ rolling_restart workflow mapping
- 跨工具数据流：`net_recorder` 节点的 **operation inputs 里 get_attribute**（任务期求值）拿 TF output → bash env → runtime property
- Day-2：`cfy executions start rolling_restart -b finale -p batch=2`（06 的工作流，无 restart 接口的底座节点自动跳过）

## When to Use

- 多工具交付要「一个按钮」：IaC 底座 + 容器 + 配置管理 + K8s 工作负载在同一部署里，生命周期/依赖/Day-2 统一
- 对照 Terraform 多模块 + shell 粘合、Pulumi 多 provider 程序——TOSCA 版的差异在**关系钩子承载配置**与**第二工作流**

## Quick Start

```bash
./hybrid_finale.sh    # 4 相 16 断言：install / dataflow / day2 / uninstall（两遍全绿）
```

前置：实验 05-09 的插件已在 venv（handson/handson-flow/docker/kubernetes 均装）；labs/01 的 docker provider 二进制（mirror 自动 stage）；kind cfy-lab（自动创建）。

## How It Works

### 五世界的安装顺序（关系推导）

`tf_base`（create：terraform apply）→ `web`（docker 插件 create）→ `net_recorder`/`configurator` 的 establish（ansible + TF output 录制）→ `check`（HttpCheck 轮询到 200）→ `k8s_master/k8s_web`（与主线**并行**的独立分支——无依赖关系时图自动并发）。日志行序断言：TF create < web create < k8s 子图完成 < HttpCheck 到 200。

### 跨工具数据流的正确通道（本实验最重要的实测结论）

TF 的 output 要流进**另一个节点的运行期**，只有一条路：**operation inputs 里的 get_attribute**（任务调用期求值——此时 TF 已发布输出）。写在 `resource_config`（模板属性）里的 get_attribute 是 **plan 期求值**——TF 还没跑，拿到空值（实测 `TypeError: unhashable type: dict`）。这一条适用于所有「上游任务的产物 → 下游任务参数」的场景。

### ansible 干真活（幂等服务）

web 容器用 `python:3.12-slim`（有 python3 供 ansible 连接）**且必须 `command: sleep infinity`**（slim 默认 CMD 是 REPL，detach 后秒退——ansible 报 unreachable=1 的真凶）。playbook 四任务：copy motd / 渲染 /srv/index.html / `pgrep` 守卫 / 启动 `python3 -m http.server 80 --directory /srv`——**shell 任务用守卫实现幂等**（重复跑 changed=0）。inventory 显式 `ansible_python_interpreter: /usr/local/bin/python3`（ansible 的解释器探测列表不含裸 python3，slim 的 python3 在 /usr/local/bin）。

## Pitfalls & Q&A

1. **get_attribute 的两种求值时机**（上面已述）——这是 TOSCA 最值得记住的语义分界。
2. **k8s 插件 delete 422**（14 已知同族）：uninstall 时 k8s 部分由 kubectl 按名兜底（TF 与 docker 部分插件正常删除，日志 `tf destroy done` 留证）。
3. **K8s 资源按名清**：Service 对象自身无 label，`delete -l app=...` 删不到它——按名删（deploy/svc/cm 三个都点名）。
4. **NodePort 复用 14 的映射**（30080→28120）：kind extraPortMappings 在建集群时固定，重建才能加映射；14 uninstall 后 30080 空闲，终局直接复用。
5. **多工作流插件共存**：一张蓝图 import 5 个 vendor plugin.yaml（docker/kubernetes/handson/handsonflow + types），插件名互不冲突即可；rolling_restart 对无 restart 接口的节点自动跳过（06 的 `has_operation` 过滤）。
6. outputs 的 `concat` 演示了跨节点属性拼装（容器 ID + 端口）——终局 outputs 三项分别来自自写插件/输入/拼接。

## 产物清单

- `tf_module/` + `scripts/{tf_apply,tf_destroy,record_network}.sh` + `scripts/rel_establish16.py` + `playbooks/site.yaml`
- `bp.yaml`（五世界 + 两自定义类型 + workflow mapping）+ `manifest16.yaml`（ConfigMap+Deployment+Service）+ `kubeconfig.yaml`
- `hybrid_finale.sh`：4 相 16 断言全绿（两遍）；`.logs/` 留档
