# 14 · Kubernetes 插件：官方插件在本地模式部署 kind

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 14 · 阶段四「Kubernetes 与交付闭环」
> 官方 `cloudify-kubernetes-plugin` 本地模式可用（与 08/09 的 terraform/ansible 不同族！）——kubeconfig 随蓝图分发，FileDefinedResource 应用 Deployment+Service 到专用 kind 集群

## Background

08/09 实测官方 terraform/ansible 插件本地秒败后，k8s 插件是**同一代插件里唯一本地可用**的——`file_resource_create` 直接走到 Kubernetes API 调用层。这让「Cloudify 编排 K8s」的演示不必等 Manager：kubeconfig 用 `blueprint_file_name` 变体随蓝图分发，资源用 `FileDefinedResource`（manifest.yaml 进蓝图目录）。与 pulumi/09（Pulumi K8s provider）同题对照：push 模型 + 蓝图声明 vs 程序化 provider。

## What

- 专用集群 `kind-cfy-lab`（cluster-config.yaml：extraPortMappings 28120→30080）；**双镜像都导入**（kind 节点不共享宿主镜像，滚动更新的新镜像也要预导入——实测 ImagePullBackOff）
- `bp.yaml`：`cloudify.kubernetes.nodes.Master`（顶层 `configuration.blueprint_file_name`）+ `FileDefinedResource`（`file.resource_path`）connected_to master
- 生命周期：install 应用 Deployment+Service → kubectl set image 滚动更新 → poststart 重读 → uninstall
- 负向留证：官方 `update_resource_definition` 工作流与 delete 写路径 422

## When to Use

- 本地模式演示/测试「Cloudify 编排 K8s」——读路径完整可用；写路径（update/delete）受限见 Pitfalls 3
- Manager 上线后同一蓝图可平移（kubeconfig 换 manager_file_path 或 secrets）

## Quick Start

```bash
./kubernetes_plugin.sh    # 5 相 14-16 断言：cluster / install / update / negative / uninstall
```

前置：kind + kubectl；依赖修复一次（README Pitfalls 1，装进 cloudify/.venv）。

## How It Works

### 依赖修复链（--no-deps 之后的真实依赖）

`kubernetes==26.1.0`（**必须降级**：插件用位置参数调 API，30+ 的 pydantic v2 强校验版直接 `Missing required argument`——这是探活时第一个失败点）+ `azure-mgmt-containerservice azure-identity google-auth`（cloudify_azure_sdk 的 AKS 分支 import，不用 AKS 也要装）+ `cloudify_importer` stub（内部化裸 import，零使用）+ `mgmtworker` stub（shared_cluster 的 Manager 兜底 import，符号全部 `NotImplementedError`）+ 升级 `requests-toolbelt bottle jinja2`（py3.11 兼容）。

⚠️ **升级老包时 uv 的 resolver 会顺手把 `cloudify-common` 降级**（`cloudify-types 5.2.3` 的依赖钉子）——CLI 自己会因此报 `ipv6_url_compat` ImportError。装完必跑 `cfy --version` 自检，坏了就 `uv pip install cloudify-common==7.0.5` + 卸 cloudify-types。

### 生命周期与滚动更新

- install：`file_resource_create` 对 manifest.yaml 的每个资源（Deployment、Service，`---` 分隔自动拆）调 API；uninstall 走 delete（受限，见下）
- 滚动更新：`kubectl set image` + `rollout status`（新 RS ready、旧 RS 缩 0）；随后 `execute_operation poststart` 让**插件重读集群实况**写回 runtime properties——收敛证据在插件状态里
- 官方 `update_resource_definition` 工作流（对照负向）：changes 必须带 `kind`+`metadata.name`（`update_with_additions` 靠它匹配，不带**静默丢弃**）；即便如此它把 POSTSTART 读回的**全量 definition**（含 status/managedFields）PUT 回去，新版 API server 422 `Deployment does not have minimum availability`

## Pitfalls & Q&A

1. **依赖链长但可修复**（见上）；两个 stub 模块都在 venv site-packages，README 说明了为什么能 stub（零使用 / 仅 Manager 功能）。
2. **kubeconfig 必须用外部地址**：`kind get kubeconfig --name X --internal` 的 server 是容器内域名（`cfy-lab-control-plane`），本地模式解析不了（DNS 失败留证）；外部版（127.0.0.1:port）直接可用。**改 kubeconfig/manifest 后必须重新 `cfy init`**——init 时的快照才生效。
3. **插件写路径 422**（kubernetes 26.1 + kind v1.36 组合实测）：update_resource_definition 工作流 422；uninstall 的 delete 亦然 → 脚本 kubectl 兜底清理 + 断言零残留。create/read 完全正常。上 Manager（插件 wagon + client 版本受控）可能规避。
4. **`kind get clusters | grep -q` 的 SIGPIPE 假失败**：grep -q 匹配即退出 → 写端 SIGPIPE → pipefail 把整条管道当失败 → 误判"集群不存在"重复 create。用 `[[ "$(cmd)" == *pattern* ]]`。
5. **set -e 静默退出**：`code=$(curl ...)` 赋值语句的退出码就是 curl 的（56=连接失败）——裸赋值会中断脚本且无输出。所有探测性命令 `|| true` + 轮询断言。
6. 重复 install 对已存在资源 `exists. Not executing operation`（不会应用新 spec）——脚本先 delete 再 install 保证可重跑。

## 产物清单

- `bp.yaml`（Master + FileDefinedResource）+ `manifest.yaml`（Deployment+Service）+ `kubeconfig.yaml`（脚本生成，不入库必要）+ `cluster-config.yaml`（28120→30080）
- `kubernetes_plugin.sh`：5 相 14-16 断言全绿（两遍）；`.logs/` 留档
