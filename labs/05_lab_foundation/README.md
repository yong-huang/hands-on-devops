# 05 · 集成点①：靶场环境——`make lab-up` 一键拉起整个系列的地基

> 前四个实验每次都要临时起容器、临时找端口。从本实验起，系列有了固定靶场：**nginx 目标应用 +
> 私有 registry + MinIO + Gitea**，一条 `make lab-up` 拉起、一条 `make lab-down` 全清。
> 后面 25 个实验不再自建基础设施——它们消费这个靶场，如同真实团队消费一台共享的构建服务器。

## 1. 为什么需要它

分散的实验基础设施有三个问题：每次重建浪费时间（拉镜像、等就绪）；各实验端口/配置漂移；
以及最重要的——**没有"同一套基础设施"就讲不出集成故事**。本实验用 Terraform（01-04 的全部
成果）声明靶场的期望态：

- **nginx**（:28085，长驻靶场专用段——28080=实验01、28081/28082=实验02、28090-28095=实验04，全错开）：后续部署/漂移/监控的"业务"；
- **registry**（:5500）：实验 12-15 推镜像、实验 20 部署时拉镜像；
- **MinIO**（:9100，容器内仍 9000；与 hands-on-mlops 的 90xx 错开）：S3 兼容存储，实验 29 的备份对象；
- **Gitea**（:3300）：实验 18/20 的代码源、实验 21 的 GitOps 仓库（管理员 `devops/devops123`）。

## 2. 总览：核心机制一图看懂

![lab foundation](images/lab_foundation.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/05_lab_foundation/images/lab_foundation.html)
> （或本地打开 [`images/lab_foundation.html`](images/lab_foundation.html)）。

看图方法：左侧 Terraform 收敛出网络里的四件套（实线）；右侧三类后续实验按需消费对应服务
（虚线）。所有数据都在命名卷里——destroy 全清，重建即空白，备份/恢复留到实验 29 演练。

## 3. 快速开始

```bash
make lab-up        # 等价于 cd labs/05_lab_foundation && ./lab_foundation.sh apply
make lab-status    # 健康检查 + endpoints 清单
make lab-down      # destroy 全清
```

真实输出（apply 与 observe）：

```
=====> [apply] 拉起靶场：nginx + registry + minio + gitea
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
    [ok] nginx 应用 就绪
    [ok] 私有 registry 就绪
    [ok] MinIO 就绪
    [ok] Gitea 就绪
    [ok] 管理员 devops 创建成功

=====> [observe] 靶场健康检查 + 服务清单
NAMES          STATUS                        PORTS
lab-gitea      Up About a minute             0.0.0.0:3300->3000/tcp
lab-registry   Up About a minute (healthy)   0.0.0.0:5500->5000/tcp
lab-nginx      Up About a minute (healthy)   0.0.0.0:28085->80/tcp
lab-minio      Up About a minute (healthy)   0.0.0.0:9100-9101->9000-9001/tcp
```

## 4. 核心概念

### 4.1 靶场也是一种基础设施

靶场本身用 TF 管理（不是一堆 docker run 脚本），意味着它拥有实验 1-4 的全部能力：
plan 漂移检测、幂等重建、模块化。教学点正是**"环境本身也是 IaC"**——给新同学的环境
就是一句 `make lab-up`。

### 4.2 容器网络即服务发现

四件套都挂在自定义网络 `devops-lab` 上，**容器名就是 DNS**：Gitea 想连数据库、registry
想对接 storage，都直接用容器名。宿主机访问走端口映射（28085/5500/9100/3300，
本系列专用段，避开 macOS AirPlay 的 5000 等常见占用）。

### 4.3 健康检查是"apply 完成"的定义

脚本不裸 sleep：`wait_http` 轮询每个服务的健康端点（nginx `/`、registry `/v2/`、
MinIO `/minio/health/live`、Gitea `/api/healthz`），全部就绪才执行下一步。
Gitea 管理员也是就绪后用 CLI 创建：

```bash
docker exec -u 1000 lab-gitea gitea admin user create \
  --username devops --password devops123 --email devops@lab.local --admin
```

**坑**：`docker exec` 默认以 root 执行，而 Gitea 拒绝 root 跑 CLI——必须 `-u 1000`
（镜像内的 git 用户），报错是 "Gitea is not supposed to be run as root"。

### 4.4 数据卷与"可弃性"

registry/minio/gitea 的数据全部进命名卷。设计取向：**destroy 全清、重建为空**——
靶场是可以随时推倒重来的；"生产数据不能丢"这件事本身是实验 29（备份恢复）的主题，
届时你会亲手演练"没备份就毁灭"。

## 5. HCL 关键字段

```hcl
resource "docker_container" "registry" {
  env = ["REGISTRY_STORAGE_DELETE_ENABLED=true"]  # 开删除 API：实验 13 的 GC 必需
  ports { internal = 5000  external = var.registry_port }   # 容器内固定 5000
  volumes { volume_name = docker_volume.registry_data.name
            container_path = "/var/lib/registry" }         # 数据出容器
}

resource "docker_container" "gitea" {
  env = ["GITEA__security__INSTALL_LOCK=true",              # 跳过安装向导
         "GITEA__server__ROOT_URL=http://localhost:${var.gitea_port}/"]
}
```

坑清单：

- **坑① Gitea 环境变量映射**：`GITEA__security__INSTALL_LOCK` 双下划线对应 app.ini 的
  `[security] INSTALL_LOCK`，段名和键名都区分大小写；
- **坑② 端口冲突静默失败**：registry 撞上 macOS 的 AirPlay(5000) 会起不来——本系列
  全部端口先探后用（`scripts/load_resources.sh` 与 README 端口表）；
- **坑③ 健康检查命令里的镜像能力**：alpine 系镜像没有 curl，healthcheck 用 `wget -qO-`。

## 6. 文件结构

```
05_lab_foundation/
├── README.md               # 本教程
├── lab_foundation.sh       # apply / observe / clean（root Makefile 的底座）
├── configs/
│   ├── versions.tf         # provider 约束
│   ├── variables.tf        # 端口与 Gitea 管理员参数
│   ├── main.tf             # 网络 + 四件套容器 + 数据卷
│   └── outputs.tf          # endpoints 服务清单
└── images/                 # 图三件套（json/html/svg）
```

## 7. 深入要点

- **为什么用 IaC 管理测试环境？** 环境可重现、可销毁、可审计；"临时的环境"更需要
  声明式——手工搭的靶场没人敢删，IaC 的靶场 `destroy` 毫无心理负担。
- **容器间如何互访？** 自定义 bridge 网络内置 DNS：容器名即主机名。端口映射只服务于
  宿主机访问，容器互联不需要也不应该映射到宿主机。
- **如何定义"服务就绪"？** 健康端点 + 轮询超时（wait_http），而不是 sleep 固定秒数；
  readiness 是部署编排（K8s readinessProbe 的前身思路）的基本功。
- **共享基础设施与实验自足怎么平衡？** 靶场提供"重"服务（Git/S3/registry），实验自带
  "一次性"对象（容器、仓库）。destroy 靶场只损失可重建物。
- **教学弱口令和生产边界？** 靶场用 devops/devops123 是刻意简化并明示；生产环境口令
  走密钥管理（实验 24 的 SOPS/Vault 选型）。

## 8. 总结

靶场就位，系列的"地基"阶段收官：01 资源 → 02 模块 → 03 状态 → 04 多环境 → 05 一键靶场。
第二阶段进入配置管理四大代际：Ansible（06-07，push 模型 + 测试）、Salt（08，masterless）、
Chef/InSpec（09，合规即代码）、Puppet（10，pull 模型）——四代工具，同一台靶场，四种哲学。

---

## 阶段一自检清单（实验 01-05，真机实测）

- [x] `bash -n` 全部通过；5 个主演示脚本 `all` 模式全流程 exit=0
- [x] clean 后零残留：5 个脚本都有"容器/网络/卷"三重断言
- [x] 幂等验证：实验 01 二次 plan exit=0；实验 02/04 重复 apply No changes
- [x] 漂移注入真实触发：实验 01 手动 stop → plan -detailed-exitcode=2 → apply 回正
- [x] 锁互斥真实触发：实验 03 `Error acquiring the state lock`（Lock Info 含 ID）
- [x] 敏感值真实取证：实验 03 从 MinIO 拉原始 state grep 出明文 token
- [x] 图三件套 25 张中的 5 张：全部过 showcase 九项门禁 + 四视口零溢出 + SVG 像素居中
      （左右留白差 ≤0.2pp；质心 -4.7% ~ +7.1%，其中 02 号图 +7% 右倾为内容固有形变，
      按规范接受并如实记录）
- [x] 环境对抗真实记录：GitHub 不可达→provider 离线镜像（scripts/tfrc.sh）；OrbStack
      假死→socket 探测（scripts/docker-env.sh）；Docker 29 API→provider 钉 3.9.0；
      端口污染→系列专用端口段
- [ ] `make lab-up` 全新机器 ≤10 分钟（依赖网络速度，镜像预载后约 2 分钟）
