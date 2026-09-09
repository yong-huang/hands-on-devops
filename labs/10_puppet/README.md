# 10 · Puppet：agent 拉模型与四代配置管理总对比

> Puppet 是声明式配置管理的原型机（2005）：受限 DSL、catalog 编译、agent 定时拉取。
> 按清单预案，本实验先探活 puppetserver 镜像（⚠️ 当前网络拉取失败，如实记录），降级为
> `puppet apply` 单容器模式——master/agent 的架构对照保留在图与 §4.3，DSL 学习目标不打折。

## 1. 为什么需要它

学 Puppet 不是为了多会一个工具，而是补齐一张对照表：

- **DSL 风格**：受限语法（vs Chef 的全量 Ruby）——表达力换可读性；
- **拉模型**：节点定时拉取期望态（vs Ansible push）——规模化与故障域的另一种答案；
- **catalog 编译**：先编译成资源图再执行——声明式语义最纯粹的实现。

## 2. 总览：核心机制一图看懂

![puppet apply](images/puppet_apply.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/10_puppet/images/puppet_apply.html)
> （或本地打开 [`images/puppet_apply.html`](images/puppet_apply.html)）。

看图方法：上半是标准形态（manifest 同步到 Server → agent 定时拉 catalog）；
下半是本实验实测路径（`puppet apply` 本地读取、立即收敛）。两者共用同一套 DSL，
差别只在"谁来编译、何时执行"。

## 3. 快速开始

```bash
cd labs/10_puppet
./puppet_apply.sh            # 语法检查 → apply → 幂等 → facts → clean
./puppet_apply.sh idempotent # 单独验证幂等（--detailed-exitcodes）
```

真实输出（关键节点）：

```
=====> [apply] DSL 静态检查
        [ok] 语法通过
=====> [apply] puppet apply site.pp（首次收敛）
        Notice: Applied catalog in 68.77 seconds     # 含 apt 装 nginx（模拟架构较慢）
=====> [idempotent] 二次 apply
        [ok] exit=0 无任何变更，幂等达成              # --detailed-exitcodes
宿主机 curl :28098/healthz → app=puppet-lab env=dev
```

## 4. 核心概念

### 4.1 DSL：class、资源、依赖箭头

```puppet
file { '/etc/nginx/conf.d/app.conf':
  ensure  => file,
  content => epp('webapp/app.conf.epp', {'app_name' => $app_name}),
  require => Package['nginx'],          # 依赖：配置需要包先装好
}

exec { 'reload-or-start-nginx':
  refreshonly => true,                  # 只在订阅对象变化时执行 ≈ handler/onchanges
  subscribe   => File['/etc/nginx/conf.d/app.conf'],
}
```

资源类型、属性、元参数（require/subscribe/refreshonly）三件套表达一切。
`puppet parser validate` 是语法门（进 CI 的第一关）。

### 4.2 catalog：两段执行的声明式

Puppet 先把 DSL **编译**成 catalog（该节点的资源依赖图），再按图执行。
错误在编译期暴露（比如引用不存在的资源），而不是执行到一半——这是它比
"直接跑脚本"更接近 Terraform 的地方（plan 也是编译出的执行计划）。

### 4.3 master/agent 拉模型 vs 本实验的 apply 形态

| 维度 | Server + agent（标准） | puppet apply（本实验实测） |
|:---|:---|:---|
| 触发 | agent 30min 定时/被动触发 | 手动/CI 一条命令 |
| 编译位置 | Server 按节点编译 | 节点本地编译 |
| 失效域 | Server 挂了只延迟不破坏 | 无服务端，无此问题 |
| 适合 | 数千节点长期收敛 | 镜像构建/小环境/学习 |

⚠️ **探活记录**：`puppet/puppetserver-standalone` 拉取失败（registry 镜像 EOF，
重试 2 次），且 JVM 服务在 Rosetta 模拟下代价过高——按 devops.md 预案降级，
保住 DSL/资源模型/幂等目标。

### 4.4 四代配置管理总对比（06-10 收官表）

| 维度 | Ansible 06 | Salt 08 | Chef 09 | Puppet 10 |
|:---|:---|:---|:---|:---|
| 语言 | YAML + Jinja | YAML + Jinja | Ruby DSL | 自研 DSL |
| 模型 | push（ssh） | 两者皆可 | pull（agent） | pull（agent） |
| 编译 | 无（即席执行） | 无 | compile→converge | catalog→apply |
| 幂等表达 | 模块+changed_when | 状态模块+onchanges | 资源+notifies | 资源+refreshonly |
| 学习曲线 | 最低 | 低-中 | 高（Ruby） | 中（DSL 规则多） |
| 一句话 | 最快上手 | 事件与规模 | 程序员的配置 | 合规企业户 |

## 5. 关键字段

```puppet
exec { 'first-start-nginx':
  command => '/usr/sbin/nginx',
  unless  => 'pgrep -f "nginx: master"',   # 幂等护栏：在跑就不再启动
  require => File['/etc/nginx/conf.d/app.conf'],
}
```

坑清单（全部真实踩过）：

- **坑① 模块目录深度**：`modules/webapp/init.pp` 不对，必须
  `modules/webapp/manifests/init.pp`，否则 class 找不到；
- **坑② site.pp 路径**：环境布局是
  `code/environments/production/manifests/site.pp`，少一段就 "Could not find file"；
- **坑③ apt 索引为空**：puppet package 装包前需要 apt-get update（本实验放在脚本
  准备步骤；生产在镜像层解决）；
- **坑④ 判定幂等用 --detailed-exitcodes**：0 无变更 / 2 有变更 / 4 失败——
  与 terraform plan -detailed-exitcode 同一思想；
- **坑⑤ 依赖失败级联**：Package 失败后 File/Exec 显示 "Skipping because of failed
  dependencies"——依赖图让故障影响面一目了然。

## 6. 文件结构

```
10_puppet/
├── README.md                        # 本教程
├── puppet_apply.sh                  # apply / idempotent / facts / clean
├── site.pp                          # 节点入口（default 节点应用 webapp class）
├── modules/webapp/
│   ├── manifests/init.pp            # class webapp：package/file/exec 资源
│   └── templates/app.conf.epp       # EPP 模板（参数化渲染）
└── images/                          # 图三件套（json/html/svg）
```

## 7. 面试要点

- **Puppet 的 catalog 是什么？** DSL 编译出的资源依赖图（该节点的期望态快照），
  执行按图进行；编译期即可发现引用错误——先规划后执行的声明式典范。
- **refreshonly 与 subscribe 组合的语义？** 资源默认不执行，仅当订阅的资源配置
  真变化时触发一次——等价于 Ansible handler、Salt onchanges、Chef notifies。
- **agent 拉模型为什么抗规模？** 编译压力分摊到服务端集群、执行分摊到节点自身，
  网络方向是"节点主动出站"，无需控制机维护海量入站连接。
- **四代工具的选型建议？** 小团队/云原生 → Ansible（低门槛 push）；超大 fleets 或
  需要事件驱动 → Salt；强合规与 Ruby 能力 → Chef；企业长期基线 → Puppet。
  现代趋势：运行期配置下沉 K8s 控制器，配置管理向"镜像构建期 + GitOps"迁移。

## 8. 总结

第二阶段收官：Ansible、Salt、Chef、Puppet——两代语言（YAML/Ruby）、两种方向
（push/pull）、两套哲学（即席编排/长期收敛）全部上手过。第三阶段进入交付物本身：
**镜像与制品**——瘦身（11）、Packer（12）、私有 Registry（13）、SBOM 与签名（14），
最后在实验 15 串成手工发布流水线。
