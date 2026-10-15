# 07 · Python 对照：两种外壳，一本账

> 把 01 号实验的 TS 版同题重写成 Python：网络 + nginx 容器 + url 输出，一行对
> 一行。程序换了语言，引擎与账本（state，记录每份基础设施期望态的档案）纹丝
> 不动——`pulumi stack export` 出的两份账本，资源类型、逻辑名（程序里写的资源
> 代号）、inputs 键名逐字一致。
>
> 两栈（stack，一份独立环境及其账本）并存各占一个端口，互不干扰。

## Background

01 号实验的 TS 版成品在手（[`../01_docker_provider`](../01_docker_provider/)），
"换 Python 写同一道题"验证的是一个更大的判断：期望态模型与语言无关，SDK 只是
外壳。外壳换掉、账本若变了样，多语言就是假话——export 对比能当场证实或戳穿。

Terraform 生态里换语言意味着整套工具切换（CDKTF，Terraform 官方「用通用编程
语言生成 Terraform 配置」的另一条产品线，从写法到工具链整套另起炉灶）。

Pulumi 把多语言做成同一引擎的多个前端：TypeScript、Python、Go、C# 共享同一套
CLI、provider（对接 Docker/某个云平台的插件）与 state 格式（即账本的存储
格式）。本实验用 Python 前端把 01 号题面重写一遍，拿账本对答案。

## What

**定义**：Python SDK（PyPI 包 `pulumi` 与 `pulumi_docker`）与 TS 包一样，都是
"声明资源、交给引擎"的前端；`Pulumi.yaml` 里 `runtime: python` 加
`virtualenv: .venv`，CLI 就会自动用这个 venv 执行程序。

| 部件 | Python 写法 | TS 对照（01 号实验） |
|:---|:---|:---|
| 命名前缀 | `pulumi.get_project()` | 常量 `"pulumi01"` |
| 读端口 | `config.get_int("port")`（缺省 28511） | 无——`external: 28081` 写死 |
| 建资源 | `docker.Network("net", name=…)` | `new docker.Network("net", {…})` |
| 复杂属性 | `ContainerPortArgs(internal=80)` | 对象字面量 `{ internal: 80 }` |
| 属性名 | snake_case：`networks_advanced` | camelCase：`networksAdvanced` |
| 字符串拼接 | f-string `f"{project}-net"` | 模板串 `` `${appName}-net` `` |

可以把"换 SDK"想象成同一份图纸的中英双语版：施工队（引擎）、验收单（账本）、
门牌规则（URN）一个字没变，变的只是图纸的语言。

失效边界：语言生态的差异是真实的——Python 没有部署前的编译期类型检查，属性名
拼错要到 `up`（Pulumi 的部署命令）执行程序时才报 `TypeError`，TS 版 `tsc`
（TypeScript 编译器命令）在部署前就拦下。

![两种外壳，一本账](images/python_parity.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/07_python_parity/images/python_parity.html)（或本地打开 [`images/python_parity.html`](images/python_parity.html)）。

看图方法：上下两行完全镜像——TS 程序与 Python 程序各自 `pulumi up` 成一本
栈账本，再收敛出各自的 nginx 容器；中缝虚线是 parity 段的 export 逐项对比。

## When to Use

- 团队主语言是 Python：IaC（Infrastructure as Code，基础设施即代码）与
  业务代码共用一套 venv、lint、测试习惯；
- 平台组与业务组分工：平台组用 TS 封组件，业务组用 Python 调用，账本互不相干；
- 把基础设施声明嵌进 Python 工具链（数据处理管线要按需拉起环境）。
- 反例：为对照而对照——一个项目里塞两种语言各写一遍，只会双倍维护。

## Quick Start

前置：Pulumi CLI、python3（≥3.9，本机 3.13 实测）、Docker 运行中。venv 与
Python SDK 首跑自动创建、安装（本机 pip 配置了清华源，约 1 分钟）。

```bash
cd pulumi/07_python_parity
./python_parity.sh          # 完整生命周期：apply → parity → isolate → clean
./python_parity.sh apply    # Python 栈上线（端口 28511）
./python_parity.sh parity   # 拉起 01 的 TS 栈，export 逐项对比
./python_parity.sh isolate  # 销毁 Python 栈，TS 栈毫发无损
./python_parity.sh clean    # 两栈全清
```

`parity` 段的真实输出（节选）：

```
        类型与逻辑名（两语言完全一致）：
        docker:index/container:Container  app
        docker:index/network:Network  net
        Container inputs 键名逐字一致——state 存 provider schema 形态，与语言无关
        属性同构：image 一致、ports 结构一致、挂网 1 条
        预期参数差异：external 端口 ts=28081 / py=28511；真名前缀各异
```

随后 `docker ps` 可见两栈并存：`pulumi01-nginx` 于 :28081、
`pulumi07-python-parity-nginx` 于 :28511，两个端口 curl 都命中 nginx 欢迎页。

诚实预期：`parity` 段会临时拉起 01 号实验的 TS 栈作对照物（结束的 `clean`
会一并清掉）；28511 与 28081 被占用会在 curl 断言处报错。

本机 Python 3.13 实测通过，Python SDK 纯 Python 实现、无需编译原生扩展。

## How It Works

### 逐行对照：同一道题的两种写法

```python
net = docker.Network("net", name=f"{project}-net")
app = docker.Container(
    "app",
    name=f"{project}-nginx",
    image="nginx:1.27-alpine",
    ports=[docker.ContainerPortArgs(internal=80, external=port)],
    networks_advanced=[docker.ContainerNetworksAdvancedArgs(name=net.name)],
)
pulumi.export("url", f"http://localhost:{port}/")
```

与 01 号实验的 TS 版逐行对应：`new docker.X(...)` 换成 `docker.X(...)`，对象
字面量换成 kwargs；复杂属性（端口、挂网〔把容器接入自定义网络，即
`networks_advanced`〕）各是一个 `*Args` 类。

**`net.name` 传进 `networks_advanced` 这条依赖边与 TS 完全同构**——依赖边
（引擎据此记住「先建网络、后建容器」；`net.name` 是创建后才知道的值）两语言
一致，引擎照样按图排序。

### 账本同构的证据：键名逐字一致

两栈各自 `stack export` 后，Container 的 inputs 键名（`image` / `ports` /
`networksAdvanced` …）逐字相同——账本里是 **camelCase**。

Python 程序写的 `networks_advanced` 只活在程序侧，进了 state 就统一成
provider schema（该 provider 声明的属性命名规范）的形态。语言的痕迹到账本为止，这正是「同一引擎」的直接证据。

### 并存与隔离：端口走配置，项目名做前缀

Python 版的端口从配置读（`config.get_int("port")`），栈 `py` 配 28511——与
TS 栈的 28081 天然错开；容器真名（Docker 里的实际名字）带项目前缀，不会与 `pulumi01-nginx` 撞名。

`isolate` 段销毁 Python 栈后，TS 栈的 28081 照常服务——不同项目、不同栈、
不同账本，互不干扰。

## Pitfalls & Q&A

- **① `*Args` 类名跟随属性名**：挂网是 `networks_advanced` 属性，Args 类就叫
  `ContainerNetworksAdvancedArgs`——想当然写 `ContainerNetworkArgs` 会
  `AttributeError`。拿不准就 `dir(pulumi_docker)` 查。
- **② 属性名拼错没有编译期拦截**：Python 侧写错 kwargs 名要到 `up` 执行程序
  时才报错；TS 侧 `tsc` 部署前就拦。Python 团队更需要 mocks 单测（mocks：不真建资源、只在内存里模拟引擎应答
  来测声明逻辑，实验 06 详解）。
- **③ venv 不用手动激活**：`Pulumi.yaml` 的 `runtime.options.virtualenv:
  .venv` 已指定，CLI 全程自动取用；装依赖用
  `program/.venv/bin/pip install -r program/requirements.txt`。

Q&A：

- **为什么账本键名是 camelCase？** state 存 provider schema 的形态（TF bridge：Pulumi 把 Terraform provider
  桥接为 Pulumi provider 的适配层，命名沿用其规范），Python 的 snake_case
  只是前端写法——两种语言在账本层汇合。
- **两种语言能混在同一个项目里吗？** 不能：一个 `Pulumi.yaml` 一个 runtime。
  对照的做法就是本实验这样——两个项目、两个栈、账本对比。
- **Python 版怎么测试？** 实验 06 的做法原样适用：`pulumi.runtime.set_mocks`（camelCase 变
  snake_case，正好又是本篇的命名对照）配 pytest；本实验聚焦对照，未重复展开。
