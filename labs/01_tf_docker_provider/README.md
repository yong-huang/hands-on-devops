# 01 · Terraform Docker Provider：给容器记账的"期望态"清单

> 手动 `docker run` 拉起的服务，三天后就没人说得清它当时为什么这样配：端口谁定的？卷挂在哪？
> Terraform 把"我要什么样的基础设施"写成代码，剩下的创建、变更、销毁全部对着清单来——本实验用
> Docker 当靶场，把这套心智在 5 分钟内跑通。

## 1. 为什么需要它

命令式地 `docker run`、`docker network create`，每一步都靠人记住。问题在**第二天**：

- 容器挂了重建，参数全靠回忆（或翻 shell history）；
- 同事问"这个容器为什么映射 28080"，没有可查的答案；
- 想把同样的服务再起一套 dev/staging，只能复制粘贴命令。

Terraform 的解法是**声明式**：你只描述期望态（期望网络、期望容器、期望端口），TF 负责算出
"当前状态 → 期望状态"的差值并执行。这份差值计算的基础，是 TF 手里的记账本——**state**。

## 2. 总览：核心机制一图看懂

![tf docker provider](images/tf_docker_provider.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/01_tf_docker_provider/images/tf_docker_provider.html)
> （或本地打开 [`images/tf_docker_provider.html`](images/tf_docker_provider.html)）。

看图方法：左边是你的 `.tf` 配置（期望态），中间是 TF 核心——拿配置和 state 记账本对比算出
diff（plan），再驱动右边的 Docker daemon（实际态）执行。**plan 检出的就是"实际偏离期望"的部分**，
实验里我们会亲手制造一次。

## 3. 快速开始

```bash
cd labs/01_tf_docker_provider
./tf_docker_provider.sh          # 完整生命周期：apply → observe → drift → clean
./tf_docker_provider.sh apply    # 只创建
./tf_docker_provider.sh drift    # 只演示"手动 stop → plan 检出 → apply 回正"
./tf_docker_provider.sh clean    # 只销毁
```

apply 之后真实输出（本机）：

```
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.
        <h1>hands-on-devops · lab01 · served by terraform</h1>
```

## 4. 核心概念

### 4.1 state：TF 的记账本

`terraform state list` 列出 TF 认为自己在管理的资源：

```
docker_container.app
docker_container.seed
docker_image.app_image
docker_network.lab
docker_volume.web_content
```

和 `docker ps` 对照（名字一一对应）：

```
NAMES        STATUS                   PORTS
tf01-nginx   Up 5 seconds (healthy)   0.0.0.0:28080->80/tcp
```

state 就是"期望态 vs 实际态"里**期望侧的底账**。它默认存本地文件 `terraform.tfstate`——
实验 3 会把它挪到远端（MinIO 冒充 S3），解决团队协作问题。

### 4.2 plan：漂移检测就是 diff

手动 `docker stop tf01-nginx` 之后，`terraform plan -detailed-exitcode` 的真实输出：

```
Note: Objects have changed outside of Terraform

  # docker_container.app has been deleted
  - resource "docker_container" "app" {
      - id   = "29b1f2ab86ea..." -> null
        name = "tf01-nginx"
```

daemon 里容器没了（实际态），配置里它该在（期望态）——diff 就是漂移。
`-detailed-exitcode` 让 plan 用退出码表达结论：`0` 无变更、`1` 出错、`2` 有变更。
CI 里正是用这个退出码做"基础设施漂移告警"（实验 28 会用到）。

随后 `terraform apply` 回正：TF 重建容器、重新挂卷，`curl` 内容恢复——**基础设施自愈**。

### 4.3 依赖图：顺序是推出来的，不是排出来的

配置里只有四条 resource，TF 依据**引用关系**自动排序：`network → volume → seed → app`。
`seed`（写首页的一次性容器）和 `app`（nginx）之间没有字段引用，必须显式
`depends_on`，否则 nginx 可能先起、首页 404。`terraform graph | dot` 可以把这张图画出来。

### 4.4 幂等：第二次 apply 应该无事可做

apply 两次，第二次 plan 应为空。验证（本机真实输出）：

```
exit=0：无漂移，plan 为空
```

幂等是 IaC 的及格线：同一个配置在任何机器上 apply 任意次，结果一致。

## 5. HCL 关键字段

```hcl
resource "docker_container" "app" {
  name  = "${var.app_name}-nginx"          # 前缀变量化：改一个变量换一套环境
  image = docker_image.app_image.image_id  # 引用 image 资源而非裸 tag，见坑①

  volumes {
    volume_name    = docker_volume.web_content.name
    container_path = "/usr/share/nginx/html"
    read_only      = true                   # 只读挂载：容器被入侵也改不掉首页
  }

  ports {
    internal = 80
    external = var.host_port                 # 端口也是参数，不写死
  }

  depends_on = [docker_container.seed]      # 显式依赖：先播种后开服
}
```

坑清单（都在本机真实踩过）：

- **坑① 假漂移·镜像**：容器直接写 `image = "nginx:1.27-alpine"`，provider 刷新时把实际
  镜像报成 `sha256:...`，与配置里的 tag 对不上，**每次 plan 都显示 forces replacement**。
  修法：声明 `docker_image` 资源，容器引用它的 `image_id`；
- **坑② 假漂移·网关**：`ipam_config` 只写 subnet 不写 gateway，daemon 回读会补出实际
  网关 → 永久 diff（ipam 变更意味着整个网络重建）。修法：subnet + gateway 写全；
- **坑③ provider 版本要对 daemon**：Docker 29 的 daemon 最低只收 API 1.44，provider 3.0.2
  只会说到 1.41，报 `client version 1.41 is too old`。本系列钉 3.9.0 并解释了原因
  （见 `configs/versions.tf` 注释）；
- **坑④ Go 客户端不认 docker context**：terraform provider / ansible docker 连接默认连
  `/var/run/docker.sock`，如果这台机器上它是软链指向未运行的 daemon（OrbStack），
  会表现为**永远卡住**。系列提供了 `scripts/docker-env.sh` 自动探测可用 socket。

## 6. 文件结构

```
01_tf_docker_provider/
├── README.md                  # 本教程
├── tf_docker_provider.sh      # 主演示脚本：apply/observe/drift/clean 四幕
├── configs/                   # 声明式配置（terraform -chdir=configs 执行）
│   ├── versions.tf            # TF/provider 版本约束 + 兼容性说明
│   ├── variables.tf           # 可调参数（名字/镜像/端口/首页内容）
│   ├── main.tf                # 网络+卷+播种容器+应用容器，含依赖与坑注释
│   └── outputs.tf             # apply 回执（URL/容器ID/资源清单）
└── images/
    ├── tf_docker_provider.architecture.json  # 图源（typed JSON IR）
    ├── tf_docker_provider.html               # 交互版（自包含单文件）
    └── tf_docker_provider.svg                # 双主题矢量图（README 内嵌）
```

## 7. 深入要点

- **plan/apply 各做了什么？** plan = 刷新实际状态 + 与期望态做 diff 得出执行计划（不改基础设施）；
  apply = 按计划调 provider API 把实际状态推向期望态。
- **state 是什么，为什么敏感？** TF 记录资源与实际对象的映射及属性快照；里面有明文敏感值
  （密码、token），所以要远端加密存储 + 严禁提交 git（实验 3/24 展开）。
- **declarative 和 imperative 的本质区别？** 声明式描述终态、可重复执行（幂等）；命令式描述
  步骤、重复执行会出错。前者让基础设施可以被 review、回滚、diff。
- **怎么检测/治理配置漂移？** 定时 `terraform plan -detailed-exitcode`，exit=2 即漂移告警；
  治理是"apply 回正 + 追查人因 + 收紧变更入口"，而不是放任手工修复（实验 28 完整演练）。
- **docker provider 能管生产吗？** 不能。它适合本地靶场与学习；生产用 K8s provider /
  云 provider——但期望态模型完全一致，这正是拿 Docker 练手的价值。

## 8. 总结

本实验建立了整条系列的主线：**配置（期望态）→ plan（diff）→ apply（收敛）→ state（底账）**，
并亲手制造与修复了一次漂移。下一个实验把这四条 resource 升级成**可复用的模块**——一处定义、
两处实例化，这是 TF 工程化的第一块积木。
