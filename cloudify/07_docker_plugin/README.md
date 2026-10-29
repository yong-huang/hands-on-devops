# 07 · Docker 插件：官方插件编排双容器与跨容器数据流

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 7 · 阶段二「插件与编排器之上的编排器」
> 官方 `cloudify-docker-plugin`（--no-deps 绕 fusion-common）起 api + web 双容器，establish 钩子把 api 的 bridge IP 写进 web 的 runtime properties

## Background

实验 01-04 用 script 插件编排「假资源」；这一步用**官方插件**编排真容器——与 labs/01（Terraform docker provider）、pulumi/01（Pulumi docker provider）三方同题：同一份「两个容器 + 关系」，三个编排器各写一遍。Cloudify 版的独有卖点：关系钩子里的**跨节点数据流**（web 拿到 api 的容器内网地址）是蓝图一等公民，不是脚本里的胶水。

## What

- `vendor/docker-plugin.yaml`：官方 plugin_1_5.yaml（`cloudify.nodes.docker.container` 类型 + `docker` 插件声明）
- api 容器（:28111）+ web 容器（:28110），`connected_to` + establish 源操作：从 api 实例的 runtime property `container`（长 ID）经 docker SDK inspect 出 **bridge IP**（OrbStack 下顶层 `IPAddress` 是 None，IP 在 `NetworkSettings.Networks.<net>.IPAddress`）写进 web 的 `backend_endpoint`
- 安装姿势：`--no-deps` 装插件包 + 手补 `docker`/`fabric`/`patchwork`/`cloudify-utilities-plugins-sdk`（插件声明的 `fusion-common` 是 Dell 内部包，PyPI/GitHub 均不存在）

## When to Use

- 容器拓扑里服务间要发现对方（地址/端口/凭据）→ connected_to + establish，而不是蓝图外脚本
- 本地模式跑插件的前提：插件模块能被 CLI venv import（pip 装进 venv）+ vendor 插件 yaml

## Quick Start

```bash
# 一次性依赖（README 命令，清单环境配置段也有）
uv pip install --no-deps <插件 zip> && uv pip install "docker>=5.0.3" "fabric>=2.5.0" "patchwork>=1.0.1" \
  && uv pip install --no-deps cloudify-utilities-plugins-sdk
./docker_plugin.sh    # 4 相 11 断言：install / dataflow / outputs / uninstall
```

## How It Works

### 插件容器节点的最小形态

```yaml
  api:
    type: cloudify.nodes.docker.container
    properties:
      client_config:
        docker_sock_file: /var/run/docker.sock     # 走本机 docker
      resource_config:
        image_tag: nginx:1.29-alpine               # 只用本机已有镜像（不 pull）
        container_args:
          name: cfy07-api
          detach: true
          ports: { "80/tcp": 28111 }
```

插件任务链：`create_container`（`containers.create` + `start`，容器长 ID 写进 runtime property `container`）→ uninstall 时 `remove_container` 零残留。镜像只认本地已有（插件不做 pull）——国内网络下这反而是优点。

### establish 拿什么传什么

api 实例 runtime properties：`container`（64 位长 ID）、`container_args`（含 ports 映射）、`container_info`（**只是 repr 字符串**，不是结构化数据）。要真实网络坐标就自己 inspect：establish 脚本（`scripts/rel_establish.py`）用 docker SDK 按 ID 查 `NetworkSettings.Networks`，拿到 `192.168.215.x` 这类 bridge IP 写进 web 的 `backend_endpoint`。

## Pitfalls & Q&A

1. **`fusion-common` 不存在**：官方 2.0.16 插件对 py≥3.7 声明的依赖是 Dell 内部包名——直接 `uv pip install` 插件必失败，`--no-deps` + 手补真实依赖是唯一本地路径。
2. **OrbStack 的容器 IP 不在 `NetworkSettings.IPAddress`**（顶层为 None），在 `Networks.<name>.IPAddress`——inspect 后要遍历 Networks。
3. **`container_info` 是 repr 不是 dict**：`<Container: e9f9654a9166>`，别当结构化数据解析。
4. **uv 从 tarball 装包时文件名必须与元数据 name 一致**（`cfy-docker-2.0.16.tar.gz` → 报 `Package metadata name 'cloudify-docker-plugin' does not match given name 'cfy-docker'`），重命名成 `cloudify-docker-plugin-2.0.16.tar.gz`。
5. **GitHub 主站 archive 偶发超时**：codeload.github.com 的 tar.gz 更稳（本实验两次下载都走了它）。

## 三方对照（labs/01 TF · pulumi/01 Pulumi · 本实验 Cloudify）

| 维度 | Terraform | Pulumi | Cloudify |
|:---|:---|:---|:---|
| 表达「web 依赖 api」 | 隐式引用（配置期） | Output/dependsOn（配置期+部署图） | 关系（含生命周期钩子，运行期数据流） |
| 运行时取对端地址 | 蓝图外手段（如 TF output + 单独脚本） | 程序里拿 Output 再喂属性 | establish 钩子内 `ctx.target.instance.runtime_properties` 一等公民 |
| Day-2 | 无部署级工作流 | 无第二工作流概念 | execute_operation / 自定义工作流对活部署操作 |
| 状态 | tfstate | state（自管后端） | 本地文件式存储（实验级） |

## 产物清单

- `bp.yaml`（双容器 + establish）+ `scripts/rel_establish.py` + `vendor/docker-plugin.yaml`
- `docker_plugin.sh`：4 相 11 断言全绿；`.logs/` 留档
