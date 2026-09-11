# 12 · Packer 镜像流水线：IaC 思想造镜像

> Dockerfile 把"怎么装"写进镜像，但装完之后的配置、加固、验证仍是手工动作。Packer 把
> 整个造镜像过程声明成代码：builder 起临时容器 → provisioner（Ansible！）做配置 →
> post-processor 打标推仓。一条 `packer build` 出厂即入库——这就是"IaC 思想做镜像"。

## 1. 为什么需要它

手工造镜像的三宗罪：步骤在文档里而不是代码里；装了什么无法审计；"本地能造，CI 造不出
一样的"。Packer 用 HCL 声明构建流水线，与 Terraform 同一哲学：**模板进 git，构建可重复，
产物可追溯**。本实验再打通实验 06：provisioner 直接复用 Ansible role——配置管理能力
被镜像流水线消费。

## 2. 总览：核心机制一图看懂

![packer pipeline](images/packer_pipeline.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/12_packer_pipeline/images/packer_pipeline.html)
> （或本地打开 [`images/packer_pipeline.html`](images/packer_pipeline.html)）。

看图方法：HCL 声明驱动六段流水线——临时容器、Ansible 配置、打标、推送、入库。
每一段失败整条流水线即失败，不存在"半成品镜像悄悄上线"。

## 3. 快速开始

```bash
make lab-up                              # 靶场提供 :5500 registry
cd labs/12_packer_pipeline
./packer_pipeline.sh build               # init → build → ansible → push
./packer_pipeline.sh verify              # registry 确认 + 拉取冒烟
```

真实输出（关键节点）：

```
        {"name":"packer-nginx","tags":["1.0.0","latest"]}
        curl :28102/healthz → app=packer-nginx env=lab
        curl :28102/ → hello from packer-nginx
        [ok] registry → pull → 运行，全链路通
```

## 4. 核心概念

### 4.1 三段流水线：source → provisioner → post-processor

- **source（docker builder）**：起一个 `python:3.12-slim` 临时容器，`commit = true`；
- **provisioner（ansible）**：`use_proxy = false` 让 Ansible 经 docker 连接进容器执行
  role（装 nginx、渲染配置、语法校验）——实验 06 的 role 结构在此复用；
- **post-processor（docker-tag + docker-push）**：打 `1.0.0`/`latest` 双标签并推
  `localhost:5500`。

### 4.2 插件机制与离线安装

Packer 1.7+ 把 builder/provisioner 拆成独立插件（`packer init` 从 HashiCorp CDN 下载
——注意：**走的是 releases.hashicorp.com，不是 GitHub**，本机可直连）。
若 CDN 也不可达，可从源码编译：`go build`（本实验留了验证过的编译产物命名规范）。

### 4.3 幂等与可追溯

同一模板重复 build，产物镜像 digest 一致（层缓存加速）；`-var app_version=x.y.z`
参数化版本号；推送到 registry 的 digest 就是发布凭证（实验 14 在其上加签名）。

## 5. HCL 关键字段

```hcl
source "docker" "nginx" {
  image  = "python:3.12-slim"
  commit = true                       # 提交容器为镜像（而非导出 tar）
  changes = ["EXPOSE 8080", "CMD [\"nginx\", \"-g\", \"daemon off;\"]"]
}

post-processors {                     # 嵌套块 = 顺序链：tag 的产物交给 push
  post-processor "docker-tag" { repository = "..."; tags = [...] }
  post-processor "docker-push" {}
}
```

坑清单（全部真实踩过）：

- **坑① 平级 post-processor 各拿原始产物**：`docker-push` 单独写会收到未打 tag 的
  `sha256:...`，直接往 docker.io 推——必须用嵌套 `post-processors {}` 块串联；
- **坑② ansible 里写 `connection: local` 会打到宿主机**：packer 插件自己生成 docker
  连接的 inventory，手工 local 反而让任务跑在你的 Mac 上（`apt` 在 mac 上当然找不到）；
- **坑③ 插件参数名变了**：新 ansible 插件用 `playbook_file`，旧内置 provisioner 是
  `playbook`——照旧文档抄会报 Unsupported argument；
- **坑④ 模拟架构下 SSH 偶发抖动**：插件经端口转发的 SSH 连容器，脚本加一次自动重试；
- **坑⑤ 官方镜像损坏的又一家**：docker builder 基础镜像若选 alpine 会缺 python3，
  与实验 06 坑①同源。

## 6. 文件结构

```
12_packer_pipeline/
├── README.md                        # 本教程
├── packer_pipeline.sh               # build / verify / clean（含失败重试）
├── nginx.pkr.hcl                    # 构建声明：source + provisioner + post-processors
└── ansible/
    ├── nginx.yml                    # provisioner 入口 play
    └── roles/nginx-pack/            # 与实验 06 webconf 同构的 role
        ├── tasks/main.yml           # apt 装 nginx → template → nginx -t
        ├── templates/app.conf.j2    # 站点配置模板
        └── handlers/main.yml        # reload（被通知才跑）
```

## 7. 深入要点

- **Packer 与 Dockerfile 的关系？** Dockerfile 描述单镜像构建步骤；Packer 编排
  "多目标（docker/cloud/虚拟机）+ 多 provisioner + 多发布目标"的构建流水线，
  且把 provision 步骤交给专业配置管理工具。
- **为什么在镜像构建期做配置而不是运行期？** 不可变基础设施：配置进镜像 →
  测试过的镜像直接上线，运行期不再改（改了就漂移，实验 28 演示）。
- **镜像构建的可追溯性？** HCL 模板版本 + 构建参数 + 产物 digest 三者绑定；
  实验 14 的 SBOM/签名再补"里面是什么、谁签的名"。
- **provisioner 选型？** shell 最通用；ansible/puppet 复用已有配置管理资产；
  这正是"配置管理资产在镜像时代继续增值"的路径。

## 8. 总结

镜像被 IaC 化了：模板即代码、构建即流水线、出厂即入库。实验 13 转向仓库运营：
认证、垃圾回收、保留策略——registry 不是垃圾桶，是需要治理的生产组件。
