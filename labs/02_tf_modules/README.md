# 02 · TF 模块化：一处定义，for_each 两处实例化

> 实验 1 里网络、卷、容器四条 resource 平铺在根模块——再来一套 blue/green 就得复制粘贴，
> 改个健康检查要改两处，漏一处就是"两个环境行为不一致"。模块（module）是 TF 的函数：
> 定义一次，参数化调用 N 次。

## 1. 为什么需要它

复制粘贴式的 IaC 有三个必然结局：

- **改一处漏一处**：健康检查从 wget 换 curl，两份代码改两遍；
- **环境漂移**：blue 和 green 的"公共逻辑"肉眼看着一样，实际已经悄悄分叉；
- **无法复用**：下一个项目要同样的 web 服务，又从零写起。

模块把"一个 web 服务长什么样"固化成 `modules/web-service`，root 只负责
"要几套、每套什么参数"。本实验两套实例（blue/green），升级镜像一条命令同步更新。

## 2. 总览：核心机制一图看懂

![tf modules](images/tf_modules.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/02_tf_modules/images/tf_modules.html)
> （或本地打开 [`images/tf_modules.html`](images/tf_modules.html)）。

看图方法：左边根模块持有实例表 `{blue, green}`，中间 `modules/web-service` 是唯一来源，
右边两个实例边界各有一套"容器+卷"。实线是容器网络关系，虚线是模块实例化与 lint 门。

## 3. 快速开始

```bash
cd labs/02_tf_modules
./tf_modules.sh            # lint → apply → observe → upgrade → clean 全流程
./tf_modules.sh lint       # 只跑 tflint（实验前置：安装见 README 环境节）
./tf_modules.sh upgrade    # 只看"改一处、两实例同步更新"
```

真实输出（节选）：

```
=====> [apply] for_each 双实例：blue(28081) + green(28082)
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
        curl blue: <h1>web-service · blue</h1>
        curl green: <h1>web-service · green</h1>

=====> [upgrade] 改模块公共逻辑：镜像 tag 升级 → 两实例同步重建
Apply complete! Resources: 4 added, 0 changed, 4 destroyed.
        curl :28081 → <h1>web-service · blue</h1>
        [ok] 一处模块定义，两处实例同步更新——这就是模块化的复利
```

## 4. 核心概念

### 4.1 module：基础设施世界的函数

```hcl
module "web" {
  source   = "../modules/web-service"   # 形参来源（本地路径模块）
  for_each = local.instances            # 实例表：blue / green
  name     = "tf02-${each.key}"         # 每个键实例化一套
  host_port  = each.value.host_port
  index_html = each.value.index_html
}
```

模块内部（`modules/web-service/`）只有镜像、卷、播种、容器四个 resource，
不含任何环境差异——环境差异全部从 `variables` 进、从 `outputs` 出。

### 4.2 for_each vs count：删一个键会发生什么

`for_each` 用 **map 键名**标识实例：删掉 `green` 键，只有 green 被销毁。
`count` 用**序号**：`count = 2` 改成 1，第 2 个实例销毁——看似一样；
但 3 个实例删第 1 个，`count` 下后两个会**重建**（序号整体前移），
`for_each` 只删指定键。有状态资源（数据库、卷）用 count 删减是灾难。

### 4.3 tflint：validate 之外的规则关

`terraform validate` 只查语法和引用；tflint 查"会踩坑的写法"。本实验开了三条规则
（`.tflint.hcl`）：过时插值语法、命名规范、声明未用的 provider。真实结果：

```
=====> [lint] tflint 静态检查（validate 之外的规则关）
        [ok] tflint 零告警
```

CI 里把 `tflint --recursive` 放在 plan 之前，坏配置根本到不了 apply（实验 25 做成正式门禁）。

### 4.4 terraform graph：依赖图即真相

```
$ terraform graph        # DOT 格式，节选
subgraph "cluster_module.web" {
  label = "module.web"
  "module.web.docker_container.web"   [label="docker_container.web"];
  "module.web.docker_volume.content"  [label="docker_volume.content"];
}
"module.web.docker_container.web" -> "module.web.docker_container.seed";
"module.web.docker_container.web" -> "module.web.docker_image.this";
```

每个实例键都展开成一套完整资源（`module.web["blue"].docker_container.web`…）。
管道给 `dot -Tsvg` 即可可视化——比在脑子里模拟 depends_on 靠谱得多。

## 5. HCL 关键字段

```hcl
locals {
  instances = {
    blue  = { host_port = 28081, index_html = "<h1>blue</h1>" }
    green = { host_port = 28082, index_html = "<h1>green</h1>" }
  }
}

variable "image" {                    # 升级变量提在根模块：
  type    = string                    # module.web[*] 共用，一处覆盖全体生效
  default = "nginx:1.27-alpine"
}
```

坑清单：

- **坑① `-var 打到未声明的变量`**：`terraform apply -var "image=..."` 要求根模块
  声明了 `variable "image"`；只声明在模块里会报 `Value for undeclared variable`。
  变量是逐层传递的，没有"全局变量"这回事；
- **坑② 模块里的 provider 约束**：模块内 `terraform { required_providers }` 只声明
  兼容范围，provider 本体由根模块安装/配置——两边版本约束冲突会在 init 时报错；
- **坑③ 相对路径的基准**：`source = "../modules/web-service"` 相对的是**模块所在的
  .tf 文件目录**（configs/），不是 cwd。这也是"任意 cwd 可跑"脚本要用 `-chdir` 的原因。

## 6. 文件结构

```
02_tf_modules/
├── README.md                    # 本教程
├── tf_modules.sh                # 主演示脚本：lint/apply/observe/upgrade/clean
├── .tflint.hcl                  # tflint 规则配置（内置 ruleset，零网络依赖）
├── configs/                     # 根模块：实例表 + 模块调用
│   ├── main.tf                  # for_each 实例化 + 镜像版本变量
│   └── outputs.tf               # 聚合两实例的 url/容器名
├── modules/
│   └── web-service/             # 可复用模块（本实验核心产出）
│       ├── main.tf              # 镜像+卷+播种+容器（带健康检查）
│       ├── variables.tf         # 输入接口：name/image/host_port/index_html
│       └── outputs.tf           # 返回值：url/container_name
└── images/                      # 图三件套（json/html/svg）
```

## 7. 深入要点

- **module 的 input/output 相当于函数的什么？** variables=形参、outputs=返回值；
  模块组合形成树，`module.web["blue"].url` 就是取深层返回值。
- **for_each 和 count 怎么选？** 有状态、需要按名字增删的用 for_each（map 键稳定）；
  无状态同质的用 count。键/序号的稳定性直接决定变更时的爆炸半径。
- **模块版本怎么管理？** 本地路径模块（本实验）随仓库演进；生产用 registry/git source
  + `ref` 钉版本，模块升级是显式变更。
- **为什么 lint IaC？** 语法正确 ≠ 写法正确。tflint 规则来自社区踩坑经验，
  在 plan 之前拦截，把"错误"变成"评审意见"。
- **Terraform 会画出依赖图，它怎么用？** 创建按拓扑序、销毁反向序；graph 让你确认
  依赖是"推导"出来的（引用）还是"声明"出来的（depends_on），后者越少越好。

## 8. 总结

模块化之后，"一套基础设施的样子"与"要几套"解耦了：实例表加一个键就扩一套，
改模块一处全体升级。但 state 还躺在本地磁盘——两个工程师（或两台 CI 机器）同时
apply 会怎样？实验 3 把 state 挪到远端（MinIO 冒充 S3），并演示状态锁互斥与
`state mv` 的正确姿势。
