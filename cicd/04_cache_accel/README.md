# 04 · 缓存与构建加速

> Docker 构建的依赖层（装包、编译工具链）占冷跑近九成的时间但很少变——分层
> 缓存把慢层缓存起来，热跑只重跑常变的源码层。本实验用 sleep 模拟慢依赖
> 安装，3 次取中位数取证：冷跑 8s → 热跑 1s，提速 87%；改 deps.lock 触发
> 缓存 miss 并取证依赖重装。

## Background

没有缓存的时代，每次 `docker build` 都从 FROM 开始逐层重建：装依赖、编译、
打包——即使绝大部分输入没变。这在 CI（持续集成，推代码即自动构建测试）里
尤其浪费：runner（CI 平台里真正执行构建任务的机器）时间白白消耗在重复安装
依赖上。

Docker 的分层缓存机制天然解决了这个问题：每层的 checksum（按层输入内容
算出的 hash 值，相当于该层的指纹）没变就直接复用。

但缓存不是魔法——COPY 的文件变了、RUN 的参数变了，该层及以下全部 miss
（缓存未命中，这些层要重新执行）。理解"什么变了会导致哪层 miss"是写出
可缓存 Dockerfile 的前提。

## What

**定义**：Docker 分层缓存是构建引擎对每层指令的增量复用——层输入（COPY 的
文件、RUN 的参数）不变时直接复用上一轮的层输出，跳过执行。

deps.lock 是依赖锁定文件（固定依赖版本的清单文件），本实验用它代表"很少变
的依赖描述"。

| 部件 | 角色 |
|:---|:---|
| `COPY deps.lock` | 缓存触发器：deps.lock 的 checksum 决定依赖层是否 miss |
| `RUN sleep 6` | 慢依赖安装层——冷跑要执行，热跑命中缓存跳过 |
| `COPY src/` | 源码层——常变，每次都重跑（但很快） |
| `--no-cache` | 强制全量重建（冷跑基线用） |

可以把分层缓存想象成做菜前的备菜：食材切配（依赖安装）提前备好，炒菜（源码
构建）时直接取用——只有换了菜谱（deps.lock 变了）才重新备料。

失效边界：与备菜不同的是，备好的食材会变质，缓存层不会过期——只要层输入
不变就一直有效。

但缓存只对本机的 Docker daemon（本机负责构建的后台服务）有效——CI 里每台
runner 的 daemon 相互隔离，跨 runner 需要显式的缓存后端（专门存放缓存的
外部存储）。

![缓存与构建加速](images/cache_accel.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/04_cache_accel/images/cache_accel.html)（或本地打开 [`images/cache_accel.html`](images/cache_accel.html)）。

看图方法：左列是两种跑法（冷跑全量 / 热跑命中），中列是 Dockerfile 的两层
（依赖层可缓存 / 源码层常变）。

右上 hashFiles（GitHub Actions 里计算文件内容 hash 的函数）检测 deps.lock
变化触发 miss，右下是计时取证结果。

## When to Use

- CI 构建时间过长：依赖安装占冷跑大部分时间且依赖文件很少变——缓存收益最大；
- 多分支并行开发：actions/cache（GitHub Actions 官方的跨任务文件缓存组件）
  或 buildx type=local（Docker buildx 把构建缓存导出到本地目录的方式）让
  runner 间共享缓存；
- 调试缓存问题：改依赖文件后缓存应 miss（本实验的 miss 段取证这一行为）。
- 怎么选：单次构建内的加速用 Docker 原生层缓存（默认就有、零配置）；只有需
  要跨 runner 共享时才引入 actions/cache（文件级、简单）或 buildx 缓存后端
  （镜像层感知、功能强）。
- 反例：构建本身只要几秒（纯静态文件）、或依赖文件每次都变——缓存的维护
  成本超过收益。

## Quick Start

前置：Docker 已启动（`docker info` 确认）。无需 act（在本机运行 GitHub
Actions 的工具）或 gh（GitHub 命令行工具）——本实验的冷/热对比用 Docker
原生分层缓存。act 的 actions/cache 兼容性需另行验证是否可用。

```bash
cd cicd/04_cache_accel   # 从仓库根出发
./cache_accel.sh           # 完整生命周期：cold → warm → miss → clean
./cache_accel.sh cold      # 冷跑：--no-cache 全量构建，计时 3 次取中位数
./cache_accel.sh warm      # 热跑：命中层缓存，计时 3 次取中位数 + 提速断言
./cache_accel.sh miss      # 改 deps.lock 触发缓存 miss（取证）
./cache_accel.sh clean     # 清镜像与日志
```

冷跑与热跑的计时取证（真实输出）：

```
        cold 3 次: 7s 8s 8s → 中位数 8s
        warm 3 次: 0s 1s 1s → 中位数 1s
        提速：8s → 1s（节省 87%）
        [ok] 热跑提速 ≥50%（87%）
```

`miss` 段改 deps.lock 后重新构建，RUN sleep 层缓存 miss（依赖重装取证
通过）；deps.lock 还原。

诚实预期：本实验的冷/热差异来自 Dockerfile 内的 `sleep 6`（模拟慢依赖
安装）——真实项目的差异取决于依赖安装的实际耗时。

## How It Works

### Docker 分层缓存：checksum 决定复用

```dockerfile
COPY deps.lock /tmp/deps.lock
RUN sleep 6 && echo "deps installed from $(cat /tmp/deps.lock)" > /tmp/deps-done
COPY src/ /tmp/src/
RUN echo "src files: $(ls /tmp/src/ | wc -l)" > /tmp/build-info
```

引擎按序检查每层的输入 checksum：`COPY deps.lock` 的 checksum 是
deps.lock 文件内容的 hash。

文件不变则 checksum 不变，后续 `RUN sleep 6` 直接复用上次的层输出（sleep
不执行）。`COPY src/` 的 checksum 每次都变（源码改了），所以源码层始终
重跑——但它很快。

### 中位数取证：为什么取 3 次

单次计时受 Docker daemon 调度、文件系统缓存等噪音影响。跑 3 次取中位数
可以过滤极端值——脚本用 `sort -n | sed -n '2p'` 提取中间值。

### miss 取证：deps.lock 变 → COPY checksum 变 → 下游全 miss

`miss` 段把 deps.lock 从 `version 1.0` 改为 `version 2.0-changed`——COPY
层的 checksum 变了，引擎不再复用该层。

该层之后的所有层（RUN sleep、COPY src/）全部 miss。构建日志里可以确认
`RUN sleep` 层没有被标记 `CACHED`——依赖被重新安装（取证通过后 deps.lock
还原）。

## Pitfalls & Q&A

- **① 只改注释也会 miss**：Dockerfile 的 RUN 指令字符串参与 checksum——
  在 RUN 行加空格或注释都会导致该层 miss。
- **② 中位数函数的 stdout 污染**：`med=$(median_of_3 ...)` 捕获函数的
  全部 stdout——函数内用 `tee` 输出诊断行时，中位数与诊断文本混在一起
  导致算术运算报错；诊断行改走 `>> $LOGS/` 直接写文件。
- **③ --no-cache 与 docker rmi 的区别**：`--no-cache` 跳过层缓存但仍
  复用 FROM 的基础镜像；`docker rmi` 删掉产物镜像但不清构建缓存——本实验
  冷跑两者都做（双保险），确保 3 次计时都不沾上一轮的缓存。

Q&A：

- **actions/cache 和 Docker 层缓存什么关系？** Docker 层缓存在同一 daemon
  内自动生效；actions/cache 是跨 runner 的文件级缓存（CI 里 runner 隔离，
  需要显式传递）。两者互补：Docker 层缓存管单 runner 内的增量，actions/cache
  管 runner 之间的缓存传递。
- **buildx type=local 和 type=gha 有什么区别？** type=local 把缓存写到本地
  目录（act 可用）；type=gha 用 GitHub 的缓存服务（只有真仓库可用）。
  本地验证用 type=local，推真仓库后换 type=gha。
- **什么放在依赖层、什么放在源码层？** 判断标准是"变的频率"：lock 文件、
  系统包、编译工具链放在前面的慢层（很少变、缓存命中率高）；源码、模板、
  配置放在后面的快层（常变但重跑成本低）。
