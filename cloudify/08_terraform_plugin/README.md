# 08 · Terraform 当一个 TOSCA 节点：script 包装主线与官方插件负向

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 8 · 阶段二「插件与编排器之上的编排器」
> labs/02 的思想反着用一遍：Terraform 模块被 TOSCA 编排——apply/outputs 回流/漂移检出/destroy 全进部署生命周期

## Background

「编排器之上的编排器」最直白的演示：把一个 Terraform 模块当一个节点。**官方 `cloudify-terraform-plugin`（0.21.6）静态 validate 通过，但本地模式实测有 Manager 硬依赖**——install 任务启动即查 Manager 运行时环境，两道闸（`LOCAL_REST_CERT_FILE` → 伪造证书后 `inet_pton(None)`；劫持 `REST_HOST` 指向不存在的端口则无限挂起等 REST 文件服务器）。为此本实验主线用 **script 插件包装本机 terraform**（三操作：apply / destroy / drift_check），官方插件保留 `bp_official.yaml` 作负向证据；上 Manager 后可平移回官方插件（蓝图接口形状一致）。

## What

- `tf_module/`：TF 模块（`count = var.replicas` 起 N 个 nginx 容器，端口 28112+，outputs names/ports）
- `scripts/tf_apply.sh`（create + maintenance.apply）：有 state 则复用（增量），无则全新；`terraform apply` 后 outputs JSON 写进 runtime properties
- `scripts/tf_refresh.sh`（maintenance.drift_check）：`plan -detailed-exitcode`（2=漂移）→ 写 `drift_detected` → `apply` 收敛
- `scripts/tf_destroy.sh`（delete 钩子）：`terraform destroy`
- `bp_official.yaml`：官方插件负向用例（validate 过 / install 秒败）
- provider 文件系统镜像：`registry.terraform.io` 本网络已被 RST，主脚本把 labs/01 已下载的 `kreuzwerker/docker 3.9.0` 二进制 stage 成 mirror（`TF_CLI_CONFIG_FILE` 指向）

## When to Use

- 已有 TF 资产要纳入统一编排（生命周期、依赖、Day-2 工作流）→ 本实验形状
- 官方插件在 Manager 上可用时优先官方插件（wagon/wagons 见清单项目 13）；本地模式用 script 包装（或把官方插件的两个 env 障碍当已知问题）

## Quick Start

```bash
./terraform_plugin.sh    # 5 相 16 断言：official-neg / install / reload / drift / uninstall
```

前置：本机 terraform（`which terraform`，实验传 `-i tf_binary=...`）+ labs/01 的 provider 二进制（mirror 自动 stage）。

## How It Works

### 「TF 模块 = 一个节点」的生命周期映射

| TOSCA 钩子 | TF 命令 | 证据 |
|:---|:---|:---|
| create | `init` + `apply -var replicas=N` | tfstate 落在部署工作目录；outputs JSON → runtime property `tf_names` |
| maintenance.apply（execute_operation 调用） | 同上（增量） | replicas 1→2 只增容器，端口 28112+28113 |
| maintenance.drift_check | `plan -detailed-exitcode`（2=漂移）→ `apply` 收敛 | 手删容器后 `drift_detected=yes`、容器恢复 |
| delete | `destroy -auto-approve` | 零容器残留 |

### TF 与编排器的两个接缝（都是实测踩出来的）

1. **state 归属**：tfstate 必须放在**可复用的部署工作目录**（`/tmp/handson08/work`）。第一版脚本每次 `rm -rf` 工作目录 → reload 时 TF 不认识存量容器 → 名字冲突报错。规则：**有 tfstate 就复用，apply 增量收敛**。
2. **变量一致性**：每次 `plan/apply` 都必须显式 `-var replicas=<当前值>`——漏传时 TF 落回模块默认值 1，`drift_check` 的"收敛"会把 web-1 **当多余资源删掉**（实测发生过）。变量的当前值属于部署状态，操作调用时经 `operation_kwargs` 传入。

## Pitfalls & Q&A

1. **官方插件负向链**（本地模式实测）：`LOCAL_REST_CERT_FILE` KeyError → 伪造 pem 后 `inet_pton() argument 2 must be str` → 劫持 `REST_HOST` 则挂起（等不存在的 REST 文件服务）。三条都有日志证据，别再花时间在本地模式硬修它。
2. **`cfy -p` 的解析规则**：整串先试 JSON（`plain_string_to_dict`）→ 传 dict 参数用**一个 JSON 对象包全部参数**；`key=value` 形式会把 dict 值留成字符串（`'str' object has no attribute 'items'`）。
3. **同名参数冲突**：operation inputs 里的键（如 `replicas`）与 `operation_kwargs` 再传同名 → `Duplicate definition ... pass allow_kwargs_override`。两个选择：调用侧传 `allow_kwargs_override: true`，或该操作在蓝图中**不声明**此 input（本实验 drift_check 用后者）。
4. **provider 下载**：`registry.terraform.io` 在本网络被 RST → 文件系统镜像复用 labs/01 二进制（`provider_installation { filesystem_mirror ... }`，mirror 按平台目录 `darwin_arm64` 布局，换平台要换二进制）。
5. **uninstall 后 runtime property 不可读**：实例记录随 uninstall 删除，delete 钩子的产出只能靠**日志**断言（`tf destroy done`）。
6. drift 收敛后 `terraform state list` 只会留下声明内的资源——收敛是"回到声明态"，不是"回到手删前快照"。

## 产物清单

- `tf_module/`（versions/main/outputs.tf）+ `scripts/{tf_apply,tf_destroy,tf_refresh}.sh` + `bp.yaml` / `bp_official.yaml`
- `terraform_plugin.sh`：5 相 16 断言全绿；provider mirror 与 tfrc 由主脚本 stage 到 `/tmp/handson08/`
