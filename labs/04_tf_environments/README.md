# 04 · 多环境矩阵：workspace 法 vs 目录法

> "dev 和 staging 就差几个参数，要不要复制一份配置？"复制之后，改公共逻辑要改两处、
> 两份配置慢慢分叉；不复制，参数差异又必须进代码。TF 有两种官方姿势组织多环境——
> 本实验把两种都跑起来，参数化端口/镜像/副本数，然后告诉你什么时候选哪个。

## 1. 为什么需要它

dev/staging 的差异通常是三类：**镜像版本**（staging 更激进）、**副本数**（staging 翻倍）、
**端口/地址**（互不冲突）。组织多环境要回答三个问题：

- 参数差异写在哪？（代码里的表 / 各环境自己的文件）
- state 怎么隔离？（同一后端按 workspace / 目录天然分离）
- 切换环境靠什么？（`workspace select` / `cd` 目录）

两种姿势对这三问给出不同答案，代价与收益在 §4.3 对比表里。

## 2. 总览：核心机制一图看懂

![tf environments](images/tf_environments.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/04_tf_environments/images/tf_environments.html)
> （或本地打开 [`images/tf_environments.html`](images/tf_environments.html)）。

看图方法：左边 workspace 法——一份配置查参数表，靠 `select` 切换出两份独立 state；
右边目录法——`envs/dev`、`envs/staging` 两个根模块各自带 state。底部是两法共用的
`modules/web`，参数差异（1.27/1.29、副本 1/2）全部从模块接口注入。

## 3. 快速开始

```bash
cd labs/04_tf_environments
./tf_environments.sh            # workspace 法 → 目录法 → 对比表 → 清理
./tf_environments.sh workspace  # 只跑方式一
./tf_environments.sh dirs       # 只跑方式二
```

真实输出（节选，两法各自独立 apply）：

```
=====> [workspace] 方式一：一份配置，两个 workspace 各自 apply
        workspace=dev：镜像 1.27 / 副本 1 / 端口 28090
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
        workspace=staging：镜像 1.29 / 副本 2 / 端口 28091+28092
Apply complete! Resources: 3 added, 0 changed, 0 destroyed.

=====> [dirs] 方式二：envs/dev 与 envs/staging 各自 apply
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
Apply complete! Resources: 3 added, 0 changed, 0 destroyed.
        [ok] 零残留
```

## 4. 核心概念

### 4.1 workspace 法：一份配置 + `terraform.workspace`

```hcl
locals {
  envs = {
    dev     = { image = "nginx:1.27-alpine", port_base = 28090, replicas = 1 }
    staging = { image = "nginx:1.29-alpine", port_base = 28091, replicas = 2 }
  }
  # 条件表达式兜底：workspace 名拼错了不至于用错参数，而是回退 dev
  env = lookup(local.envs, terraform.workspace, local.envs.dev)
}
```

每个 workspace 一份独立 state（同一后端，key 自动带 `env:` 前缀）。
`workspace list` 真实输出：

```
  default
* dev
  staging
```

副本展开用 `count = replicas`，端口 `port_base + count.index` 依次偏移——staging 的
两个副本落在 28091/28092。

### 4.2 目录法：`envs/dev`、`envs/staging` 各是一个根模块

参数直接写在各自目录的 module 调用里，没有查表逻辑；state 目录天然分离；
apply 入口就是目录——**想切错环境都难**。代价：根模块有少量重复（每个目录十几行），
公共逻辑全部下沉到 `modules/web`。

### 4.3 两法对比（结合本机实测）

| 维度 | workspace 法 | 目录法 |
|:---|:---|:---|
| 参数差异位置 | 代码里的 locals 表 | 各目录写死 / -var-file |
| state 隔离 | 同后端按 workspace 前缀 | 目录天然隔离 |
| 切换方式 | `workspace select`（易切错） | `cd` 目录（想错都难） |
| 变更影响面 | 一份配置全环境连坐 | 环境间有"物理墙" |
| 代码重复 | 零重复 | 根模块少量重复 |
| 差异可见性 | 隐藏在 map 里，漏 key 运行时炸 | 打开目录一目了然 |
| 适用 | 环境少且同构、个人/小队 | 边界要求严、生产主流 |

经验法则：**生产环境用目录法**——不同环境的变更权限、apply 频率、审查严格度都不同，
"物理墙"值这点重复。workspace 更适合同类环境的横向扩展（per-feature 临时环境）。

## 5. HCL 关键字段

```hcl
resource "docker_container" "app" {
  count = var.replicas                      # 副本数：无状态服务适合 count
  name  = "${var.name}-${count.index + 1}"  # 副本编号进名字，肉眼可辨
  ports {
    external = var.port_base + count.index  # 端口偏移：宿主机端口全局唯一
  }
  lifecycle { ignore_changes = [log_opts, network_mode] }  # 压掉 provider 假漂移
}
```

坑清单：

- **坑① workspace 切错环境**：`select` 是全局状态（.terraform/environment 里记着），
  在错误 workspace 里跑 apply 就是"对生产执行开发变更"。目录法从机制上消灭这个错；
- **坑② count 缩容的爆炸半径**：`replicas 2→1` 会销毁编号大的副本；如果先销毁了
  count.index=0 再重建，有状态服务会"换宿"——无状态才用 count（实验 02 的 for_each 对比）；
- **坑③ lookup 的 default 参数**：`lookup(map, key, default)` 第三参省略时，key 不存在
  直接报错——查表法建议永远写 default，让错误晚点炸且更可读。

## 6. 文件结构

```
04_tf_environments/
├── README.md                  # 本教程
├── tf_environments.sh         # 主演示脚本：workspace/dirs/compare/clean
├── configs-workspace/         # 方式一：一份配置 + terraform.workspace 查表
│   └── main.tf                # 参数表 + 条件表达式 + module 调用
├── envs/                      # 方式二：每环境一个根模块
│   ├── dev/main.tf            # 1.27 / 1 副本 / 28093
│   └── staging/main.tf        # 1.29 / 2 副本 / 28094-5
├── modules/web/               # 两法共用的服务模块
│   ├── main.tf                # count 副本 + 端口偏移
│   └── variables.tf           # name/image/port_base/replicas
└── images/                    # 图三件套（json/html/svg）
```

## 7. 深入要点

- **workspace 和目录法本质区别？** workspace 是"同配置多状态"，目录是"多配置多状态"。
  前者优化零重复，后者优化隔离性与差异可见性。
- **生产该用哪种？** 主流目录法：环境间变更流程/权限/频率不同，需要物理边界；
  配合 CI 按目录 path 过滤触发（labs/05 的 Makefile 就是目录法入口）。
- **环境间参数漂移怎么治理？** 参数表/TFVAR 纳入 review；用 tflint/OPA（实验 22）
  校验"staging 必须开启 X"；漂移检测（实验 28）定期 plan 比对。
- **conditional expression 在 IaC 里的正确用法？** 用于策略兜底（lookup default）与
  小分叉；大段环境差异用表驱动而不是嵌套三元——可读性即正确性。
- **多环境 + 远端 state 怎么组合？** 目录法各目录独立 backend key（实验 3 的 MinIO
  可直接复用）；workspace 法由 TF 自动加 `env:` 前缀，锁按 workspace 各自独立。

## 8. 总结

至此 Terraform 工程化四件套齐了：资源（01）、模块（02）、状态（03）、多环境（04）。
实验 5 把它们拧成一股绳：一条 `make lab-up` 拉起整个系列的靶场——nginx 应用、
私有 registry、MinIO（接手实验 3 的 state 存储）、Gitea（接手实验 18 的 git 服务）。
后面的所有实验都在这个靶场上打。

## 附：本实验的环境参数（实测）

| 环境 | 镜像 | 副本 | 端口 |
|:---|:---|:---|:---|
| workspace dev | nginx:1.27-alpine | 1 | 28090 |
| workspace staging | nginx:1.29-alpine | 2 | 28091-28092 |
| 目录 dev | nginx:1.27-alpine | 1 | 28093 |
| 目录 staging | nginx:1.29-alpine | 2 | 28094-28095 |
