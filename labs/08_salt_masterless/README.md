# 08 · Salt masterless：节点自治的声明式收敛

> Ansible（实验 6）由控制机"推"配置；Salt 的默认形态是 master-minion：节点上的 agent
> 定时向 master"拉"取期望态。本实验取第三种形态——**masterless**：`salt-call --local`，
> 节点自己读 state 树、自己收敛，一条命令、零中心依赖。跑通它，push/pull 之争就不再是口号。

## 1. 为什么需要它

master-minion 架构在生产很强（数千节点、事件总线、异步作业），但学习与小型场景里
master 是负担：要维护中心服务、证书、拓扑。masterless 保留 Salt 全部声明式能力
（state/pillar/grains/Jinja），砍掉全部中心组件——**"节点自己管理自己"**，这也是
不可变镜像构建（Packer provisioner）、容器内自配置的常见形态。

## 2. 总览：核心机制一图看懂

![salt masterless](images/salt_masterless.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/08_salt_masterless/images/salt_masterless.html)
> （或本地打开 [`images/salt_masterless.html`](images/salt_masterless.html)）。

看图方法：左侧三份数据源——state 树（要什么）、pillar（业务数据）、grains（机器事实）
——被 `salt-call --local` 读取，收敛本机 nginx 并渲染配置。对比 Ansible：把"控制机"塞进
了节点本身。

## 3. 快速开始

```bash
cd labs/08_salt_masterless
./salt_masterless.sh            # apply → 幂等 → pillar 切换演示 → clean
./salt_masterless.sh pillar     # 单独看 grain 切换 pillar 的效果
```

真实输出（关键节点）：

```
=====> [apply] salt-call --local state.apply nginx
        Succeeded: 3 (changed=3)
        curl :28096/healthz → app=salt-masterless-lab env=dev
=====> [idempotent] 二次 apply
        [ok] 无任何状态变化，幂等达成
        Succeeded: 3
=====> [pillar] grain env=dev → staging
        Succeeded: 3 (changed=2)
        curl :28096/ → hello from STAGING (grain env=staging)
        [ok] 配置内容随 grain/pillar 自动切换——数据驱动的环境差异
```

## 4. 核心概念

### 4.1 state：SLS 三段式

```sls
app config:
  file.managed:                      # 状态模块：结果应该是"这个文件内容正确"
    - name: /etc/nginx/http.d/app.conf
    - source: salt://nginx/app.conf.j2
    - template: jinja                # 渲染引擎：grains/pillar 可用
    - makedirs: true                 # 父目录不存在时自动建（否则 Parent directory not present）

nginx live:
  cmd.run:
    - name: nginx -t && (nginx -s reload 2>/dev/null || nginx)
    - onchanges:                     # 只在被监听状态真变化时执行
      - file: app config
```

声明式复读机：跑一遍是收敛，跑两遍是证明。二次 apply 真实输出 `Succeeded: 3`（无
changed 字样即零变更）。

### 4.2 pillar 与 grains：数据与事实分离

- **grains**：机器"是什么"（OS、IP、自定义事实）——`salt-call --local grains.setval env dev`；
- **pillar**：节点"该拿什么数据"——top.sls 分发，按 grain 取值：

```sls
{% set env = grains.get('env', 'dev') %}
app_env: {{ env }}
{% if env == 'staging' %}greeting: hello from STAGING
{% else %}greeting: hello from dev{% endif %}
```

把 grain 从 dev 切到 staging 再 apply，配置文件与 HTTP 响应内容**自动**切换——
环境差异是数据问题，不是代码问题。

### 4.3 与 Ansible 的模型对比（本实验实测视角）

| 维度 | Ansible（实验 6） | Salt masterless（本实验） |
|:---|:---|:---|
| 模型 | push：控制机主动执行 | 节点自治（可定时自拉） |
| 目标机依赖 | python3（raw 先装） | salt 本体在节点上 |
| 清单/拓扑 | inventory（可动态） | 无中心，top.sls 分发 |
| 变量分层 | vars 优先级 22 级 | pillar（数据）/grains（事实）清晰二分 |
| 适合 | 一次性编排、批量变更 | 长期收敛、定时自愈 |

### 4.4 四代配置管理总对比（06-10 的地图）

| 工具 | 语言/模型 | agent | 伸缩 | 一句话 |
|:---|:---|:---|:---|:---|
| Ansible | YAML · push（ssh） | 无 | 中 | 上手最快，_ssh 即清单_ |
| Salt | YAML+Jinja · push/pull 可选 | 可无 | 大 | 消息总线起家，事件能力强 |
| Chef | Ruby DSL · pull | 有 | 大 | 代码即配置，程序员味最重 |
| Puppet | 自研 DSL · pull | 有 | 大 | 最老的声明式，企业合规之王 |

## 5. YAML/SLS 关键字段

```sls
nginx live:
  cmd.run:
    - onchanges:          # 不是 watch：onchanges 只在"被引用状态变化"时执行，
      - file: app config  # watch 在部分版本组合里会每轮都跑（changed=1 幽灵）
```

坑清单（全部真实踩过）：

- **坑① Parent directory not present**：file.managed 不自动建父目录，加 `makedirs: true`；
- **坑② 发行版布局差异**：salt 镜像的 nginx 用 `http.d/` 而 debian 用 `conf.d/`——
  配置写错 include 目录，nginx -t 通过但页面永远 404；
- **坑③ watch 的幽灵变更**：`watch_in` 组合下 cmd 每轮都跑（changed=1），换 `onchanges`；
- **坑④ amd64 镜像在 arm64 mac**：saltstack/salt 仅 amd64，Docker Desktop Rosetta 模拟
  可用（性能打折），本实验如实标注；
- **坑⑤ IPv6 陷阱**：容器内 `wget http://localhost` 走 ::1，而 nginx 只听 IPv4——
  脚本统一用 `127.0.0.1`。

## 6. 文件结构

```
08_salt_masterless/
├── README.md                     # 本教程
├── salt_masterless.sh            # apply / idempotent / pillar / clean
├── saltfs/
│   ├── salt/
│   │   ├── nginx.sls             # 状态声明：pkg + file + cmd(onchanges)
│   │   └── nginx/app.conf.j2     # Jinja 模板（grains/pillar 汇合点）
│   └── pillar/
│       ├── top.sls               # 数据分发规则
│       └── nginx/init.sls        # 按 grain 分叉的业务数据
└── images/                       # 图三件套（json/html/svg）
```

## 7. 面试要点

- **masterless 和 master-minion 怎么选？** masterless 用于单节点自管/镜像构建/小型部署；
  master-minion 用于大规模实时编排与事件驱动（如自动响应证书过期）。
- **pillar 和 grains 的区别？** grains 是节点上报的事实（低频、机器相关）；pillar 是
  master/本地下发的数据（敏感、业务相关）。渲染模板时一个"是什么"，一个"该怎样"。
- **声明式收敛如何保证幂等？** 状态模块内置"读-比-改"语义；外部命令必须配
  unless/onchanges/creates 之类护栏，否则每轮都 changed（本实验的幽灵变更）。
- **Salt 与 Ansible 的伸缩差异来自哪？** Salt 的消息总线（ZeroMQ）让命令扇出异步化，
  万级节点仍秒级触达；Ansible 逐机 SSH，量大靠 forks/流水线分批。
- **什么时候用 salt-call --local？** Packer/云-init 阶段无 master 可连、隔离环境、
  以及"配置随镜像走"的不可变基础设施。

## 8. 总结

masterless Salt 证明了声明式能力与中心架构无关：砍掉 master，state/pillar/grains 的
分层依然成立。实验 9 换到 Chef——把配置写成真正的 Ruby 代码，再用 InSpec 把"验收标准"
也写成代码（合规即代码）。
