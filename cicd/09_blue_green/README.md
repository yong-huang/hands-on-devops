# 09 · 蓝绿部署——秒级切换与零停机

> 蓝绿（blue-green）= 两套等价的生产环境并存：蓝槽跑当前版本接全部流量，
> 绿槽部署新版本但不接流量；等绿槽体检通过，把入口的流量指针从蓝改到绿，
> 全程不断线。旧槽不销毁——它就是回滚位，改回指针即秒回旧版。
>
> 本实验用 Docker Compose 起双槽 nginx + 一个 edge 入口，在 ab 持续压测中
> 真刀真枪切一次槽：断言 8 万请求 0 失败，再断言回滚 < 5 秒。

## Background

labs 系列的"部署"都是起个容器就算上线，没人问过：切换那一刻，正在请求的
用户怎么办？真实发布要求**零停机**——发版期间不拒绝、不丢任何请求。

蓝绿部署的答案是用"空间换时间"：不原地升级，而是让新旧两个版本同时活着，
流量整体搬一次家。搬家只改一行 nginx 配置 + reload（nginx 的平滑重载：
不停止服务就换上新配置），毫秒级完成；出问题把指针改回去，同样毫秒级。

## What

**定义**：蓝绿部署 = 双槽等价环境 + 单一流量入口 + 原子切流。切换的单位
是"槽"（整套环境），不是单个实例——所以没有中间态，要么全蓝要么全绿。

| 部件 | 本实验的实现 | 职责 |
|:---|:---|:---|
| blue / green 槽 | 两个 nginx 容器，`/version` 返回 v1/v2 | 新旧版本同时在线 |
| edge 入口 | nginx `upstream`（声明后端服务器列表的配置块）指向当前活动槽 | 唯一对外端口 29080 |
| 切槽动作 | 改 `active.conf` + `nginx -s reload` | 毫秒级原子换指针 |
| 健康门禁 | 探活 green 的 `/version`，不过不切 | 先体检、后切流 |

可以把切槽想成"机场行李转盘"：两个转盘（槽）一直都在转，工作人员只是把
乘客指引（流量）从 A 转盘指到 B 转盘——乘客（请求）全程不用停下来。

失效边界：这个类比没覆盖"在途请求"。切槽瞬间已建立、还没响应完的请求
归旧 worker 处理——`nginx -s reload` 的优雅语义保证旧 worker 收尾完才退场，
这正是零停机的机制来源，不只是"指针一换"那么简单。

![蓝绿部署](images/blue_green.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/09_blue_green/images/blue_green.html)（或本地打开 [`images/blue_green.html`](images/blue_green.html)）。

看图方法：上行是流量面（ab → edge → blue/green 两槽 → 右侧回滚位），下行
是控制面（健康门禁 → 切槽动作）——控制面指挥流量面，但请求永远只走流量面。

## When to Use

- 发布必须零停机、且要求**秒级回滚**兜底：蓝绿是回滚最快的策略（改指针）；
- 新版本需要真机"预部署 + 预验证"：绿槽可以先起好、体检通过再接流量；
- 数据库 schema 兼容、两端可并存的场景（本实验的 nginx 玩具服务天然满足）。
- 反例：无法双份跑的资源重服务（每个实例吃几十 GB 内存）或 schema 不兼容
  的升级——双槽成本翻倍或新旧版本互踩，应考虑滚动更新（项目 11）。

## Quick Start

前置：Docker（本机 daemon 已启动）、`ab`（macOS 自带 `/usr/sbin/ab`）、
curl、python3。nginx 镜像首次运行会自动拉取。

```bash
cd cicd/09_blue_green
./blue_green.sh              # 完整生命周期：up → switch → rollback → clean
./blue_green.sh up           # 起双槽 + edge，断言初始流量全在 v1
./blue_green.sh switch       # 压测中切槽：断言 0 连接失败 + v2 生效
./blue_green.sh rollback     # 切回 v1，断言回滚耗时 < 5s
./blue_green.sh clean        # 销毁环境，active.conf 复位到 blue
```

`switch` 段的真机取证（完整输出见脚本运行日志）：

```
        [ok] 健康门禁：green /version = v2
        切槽动作（改 conf + reload）耗时 0.22s
        [ok] 压测 80297 个请求，Failed requests: 0
        [ok] 采样时间线：v1 × 28 → v2 × 53，切换空洞 0.14s
        [ok] edge /version = v2
        [ok] 旧槽 blue（v1）仍存活——这就是回滚位
```

`rollback` 段的真机取证：

```
        [ok] 回滚到 v1 耗时 0.20s（< 5s）——改回 upstream 即秒回
```

诚实预期：80297 / 0.22s / 0.14s / 0.20s 都是本机（OrbStack + 本地 ab）的
实测值，复跑数字会变但量级不变；断言的是"0 失败"与"< 5s"这两个不变式，
不是具体数字。

## How It Works

### 双槽拓扑：为什么入口只有一个

```yaml
services:
  blue:
    image: nginx:1.27-alpine     # v1，现役
  green:
    image: nginx:1.25-alpine     # v2，待命
  edge:
    ports: ["29080:80"]          # 唯一对外入口
    volumes:
      - ./conf/edge/upstream:/etc/nginx/upstream:ro
```

对外只有 edge 的 29080；blue/green 的 29081/29082 仅供脚本从宿主机直连
做体检与"旧槽保活"取证，生产环境不会暴露。edge 的全部秘密在 upstream
文件里：`upstream app { server blue:80; }`——切槽就是改这一行。

### 切槽：改文件 + reload，为什么这能零停机

`nginx -s reload` 不是重启：master 读新配置、起新 worker 接新流量，旧
worker 处理完在途请求才退场。切换瞬间已建立的连接不断、新请求直接进新槽。
采样器每 0.1s 记录 edge 的版本号，实测切换空洞 0.14s（采样粒度），
压测侧 `Failed requests: 0`。

### 健康门禁：先体检、后切流

`gate_slot` 直连 green 的 29082 轮询探活 `/version`，拿到 v2 才放行切流
（30 次 × 0.5s 内没等到就拒绝切换、流量留在 blue）。这就是"绿槽先预部署、
预验证"的机制化：不 healthy 的版本根本没有接流量的资格。

### 压测与采样的取证设计

压测打向 `/version` 而非 `/`：v1、v2 的响应体都是 3 字节。ab 会把"响应体
长度变了"记成 Length 失败，压同长度端点才能让 `Failed requests: 0` 只
反映真实掉线。采样器同时记录版本翻转时间线：v1 × 28 → v2 × 53，证明
两个版本在切换窗口内都被真实服务过。

## Pitfalls & Q&A

- **① healthcheck 里的 `localhost` 拒绝连接**：nginx:alpine 的 busybox
  wget 对 `localhost` 先试 IPv6（::1），而槽只监听 IPv4——健康检查永远
  Connection refused。改用显式 `http://127.0.0.1/version`。
- **② ab 的 Length 失败是假阳性**：开发期首次压 `/` 切槽后报 15390 个
  "失败"，明细却是 `(Connect: 0, Receive: 0, Length: 15390,
  Exceptions: 0)`——连接一个没断，只是 v2 响应体从 11 字节变成 12 字节。
  看明细，别看总数。
- **③ `compose up` 不重建未变化的容器**：上一次 switch 失败后 edge 停在
  "内存里指向 green"的状态，再跑 `up` 时文件已复位 blue、edge 却还在发
  v2——`up` 阶段必须对 edge 补一次 reload，让内存配置对齐 active.conf。

Q&A：

- **为什么不用 `docker stop blue && docker start green`？** 那是"停机换
  灯泡"：stop 瞬间在途请求全断，蓝绿的核心恰恰是"新槽先就绪、流量原子
  搬家"，靠的是 reload 的优雅语义而不是容器生命周期开关。
- **蓝绿和滚动更新（项目 11）怎么选？** 蓝绿：资源翻倍、回滚秒级、切换
  粒度是"全量"；滚动：资源平缓、逐实例替换、回滚需反向滚动。要秒回选
  蓝绿，省资源选滚动。
- **切换期间已建立的连接怎么办？** 归旧 worker 处理完——reload 只影响
  新连接的路由，不拆已有连接；采样时间线里 v1 → v2 的自然过渡就是证据。
