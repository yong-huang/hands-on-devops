# 01 · GitLab CE 单机上线：半导体内网的第一块地基

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 1 · 阶段一「入职第 1 周——把半导体内网立起来」
> 一台 Mac 变成半导体设计部门的内网代码平台：自建 GitLab CE（Community Edition 社区版，Omnibus 容器化）上线，内存减配后在 4.5GB 限额内稳态运行
> 全部断言集中在 `gitlab_up.sh verify`：平台可用性、服务完整性、Puma 减配、内存限额六条，全过打 `[ok]`

## Background

半导体公司的芯片源码、PDK 工艺库、版图数据是核心资产，几乎不可能放进公有 SaaS（GitHub.com）——代码不出内网是行业底线，所以自托管 GitLab 是这个行业的默认选型。本实验做的事，等价于「入职第一周把部门代码平台立起来」：不依赖任何云，一台 Mac 就是内网。

GitLab 不是单个进程，而是十几个组件的集合体：Rails、PostgreSQL、Redis、Gitaly（Git 存储后端，下表详解）、nginx……手工安装要撞一天编译和依赖墙。

官方 **Omnibus** 打包把这些全部塞进一个镜像：一份 `gitlab.rb` 声明所有配置，`gitlab-ctl` 一个命令管所有服务。

容器化之后，「搭平台」退化成「写一份 compose（Docker Compose 编排文件）+ 一份调优文件」。

## What

心智模型一句话：**一个容器 = 一整间机房**。`docker exec gitlab gitlab-ctl status` 能看到这些常驻服务（本实验实测 10 个）：

| 服务 | 干什么 | 一句话 |
|:---|:---|:---|
| puma | Web 应用（Ruby） | 你点到的每个页面都是它渲染的 |
| sidekiq | 后台任务队列 | 发邮件、跑 webhook、镜像同步 |
| postgresql / redis | 数据库 / 缓存 | 业务数据与队列状态 |
| gitaly | Git RPC 服务 | 所有 `git clone/push` 的真正后端 |
| nginx / workhorse | 反代 / 智能代理 | 入口流量：静态走 nginx，Git/大请求走 workhorse |
| sshd | git+ssh | `git@...` 协议的入口 |
| gitlab-kas / logrotate | K8s（Kubernetes）agent 服务端 / 日志轮转 | 附赠组件，本实验用不到 |

验证方法：`./gitlab_up.sh status` 现场看这一张表。减配后本实验省掉了 Prometheus 全家桶（监控指标导出器 exporter 一并关闭），可观测性在清单项目 24 用 API 拉数替代。

## When to Use

| 场景 | 用单机 Omnibus？ | 说明 |
|:---|:---|:---|
| 实验靶场 / 学习（本系列） | ✅ | 减配后 4.5GB 限额稳态 ~3GB，Mac 可跑 |
| 小团队内网（<50 人） | ✅ | 加好备份（清单项目 23）就能生产 |
| 大团队 / 高可用要求 | ❌ | 要拆 Postgres/Redis 外置 + 多节点，参考官方 HA 参考架构 |
| 只想要代码托管 | 视情况 | Gitea 更轻（devops.md labs/18 已做）；要 CI/CD 生态和 Runner 农场（本清单后续全部实验）就用 GitLab |

## Quick Start

前置：Docker（OrbStack 即可，需带 Compose v2 子命令）+ 端口 28200/28222 空闲（全系列分配表 28200-28279 段）。

**第一步·拿镜像（国内最大的坑，先做）**：compose 引用的 `docker.1ms.run/gitlab/gitlab-ce:latest` 常被镜像源掐断大层（1.5GB），先试多源接力，全败走兜底脚本：

```bash
# 多源接力（哪成功用哪，成功即跳第 2 步）
for m in docker.1ms.run docker.m.daocloud.io; do docker pull $m/gitlab/gitlab-ce:latest && break; done

# 全败 → 兜底脚本：R2 签名 URL 小片续传 + sha256 校验 + docker load（首次约 40 分钟，幂等可续传）
./scripts/fallback_pull.sh
```

**第二步·起平台**：

```bash
./gitlab_up.sh up        # 起容器 + 轮询就绪 + 提示 root 初始密码（首次启动 4-6 分钟）
./gitlab_up.sh verify    # 清单验收断言
./gitlab_up.sh status    # 服务状态 + 内存占用
./gitlab_up.sh stop      # 停容器（compose stop：容器与数据卷都保留）
./gitlab_up.sh start     # 秒级恢复已停止的容器
./gitlab_up.sh clean     # 销毁容器+数据卷（平台清零，想重来才用）
```

`up` 的真实输出（**首次启动**会先显示 `Pulling/Creating/Volume` 并在 healthcheck 处等 4-6 分钟；下面贴的是容器已在运行时的**二次执行**，所以秒过；密码行现场读取、此处脱敏）：

```
=====> [up] 启动 GitLab CE（首次运行会先拉 ~3GB 镜像）
 Container gitlab Running
=====> [wait] 轮询 http://localhost:28200/users/sign_in（最长 900s，每 10s 一次）
[ok] GitLab 就绪（耗时 0s）

=====> [info] root 初始密码（首次启动后 24h 内可读，登录后请立即改掉）
  Password: ****
```

`verify` 的真实输出（2026-10-29 实测，6 条全过）：

```
=====> [verify] 清单验收断言
  [ok]   users/sign_in：HTTP 200（平台可用）
  [ok]   api/v4/version：HTTP 401（rails 活性正常，未带 token 理应 401）
  [ok]   gitlab-ctl status：10 个服务全部 run，无 down
  [ok]   puma worker_processes = 2（仓库 configs/gitlab.rb 与容器内一致）
  [ok]   内存限额生效：4500MiB（docker stats 显示 3.004GiB / 4.395GiB）
  [ok]   实际内存占用 3.004GiB < 6GB

[ok] 项目 1 全部验收断言通过
```

浏览器打开 <http://localhost:28200>，用户名 `root` + 初始密码登录即完成全部目标。

诚实预期：首次启动要 4-6 分钟——Omnibus 的 reconfigure（用内嵌 chef 工具把 `gitlab.rb` 渲染成全部服务配置）加数据库迁移，期间页面 502 正常，等 `healthcheck` 打 `[ok]` 再刷新。

## How It Works

### external_url 决定一切 URL，但不决定监听端口

`external_url 'http://localhost:28200'` 让所有 clone URL、页面跳转都长成 `http://localhost:28200/semi/...`。

但 Omnibus 会顺手让 nginx 也监听 28200——而 compose 的端口映射是 `28200:80`，两头对不上就 502。所以必须显式 `nginx['listen_port'] = 80`，把「URL 端口」和「监听端口」解耦。验证：注释掉这行再 `up`，首页 502。

### 内存四大旋钮

```ruby
puma['worker_processes'] = 2             # 默认=核数；小内存官方建议 2-3
puma['per_worker_max_memory_mb'] = 1024  # 单 worker 超 1GB 自杀重启（防泄漏保险丝）
sidekiq['concurrency'] = 5               # 默认 20 线程，本实验没有重后台队列
prometheus_monitoring['enable'] = false  # 关 monitoring 与全部 exporter（指标导出器），省 ~1GB
```

验证：`docker stats --no-stream gitlab` 稳态 ~3GiB，低于清单断言的 6GB 红线。

### 挂盖式配置：卷存数据，文件盖配置

三个 named volume（config/logs/data）让 secrets、仓库、数据库跨容器重建存活。

`configs/gitlab.rb` 以单文件 ro（read-only 只读）盖挂到卷上的同名文件——仓库里 grep 到的配置就是容器里生效的配置（verify 第 4 条断言两头都查）。只有 `clean`（`compose down -v`）才会连卷一起清零。

### 就绪信号：健康端点已死，信登录页

新版 GitLab CE 默认下线了 `/-/health`、`/-/readiness`、`/-/liveness`（实测全部 404，rails 只回了 JSON Not Found）。

所以 `scripts/healthcheck.sh` 轮询的是 `users/sign_in` 返回 200——它要求 nginx → workhorse → puma → DB 全链路贯通，是比健康端点更真实的「平台可用」信号。

`verify` 再加 `api/v4/version` 401（未带 token 的正常鉴权响应）和 `gitlab-ctl status` 双确认。

## Pitfalls & Q&A

**坑 1：镜像大层（1.5GB）在国内镜像源拉不下来。** 实测三连败：`docker.1ms.run` 反复断流/层损坏；`docker.xuanyuan.me` 免费节点「繁忙」；`1panel` 403、`hub.rat.dev` 302 回 1ms 同后端。

且 Docker 拉镜像层（image layer，分层文件系统的一层压缩包）不支持断点续传，每次重试从 0 开始。**可执行解法已脚本化**：

```bash
./scripts/fallback_pull.sh   # 原理：daocloud 匿名 token → blob（内容寻址的二进制对象）请求
                             # 307（HTTP 临时重定向）到 Cloudflare R2（其对象存储）签名 URL；
                             # R2 支持 Range 断点但连接活不过 ~15-60MB → 15MB 小片顺序续传；
                             # sha256 逐个校验 → 拼 OCI layout（Open Container Initiative
                             # 镜像目录规范，docker load 认它）→ 打 tag
```

**Q：首次启动到底在等什么？** `docker logs -f gitlab` 里看 reconfigure 跑完、然后 `gitlab-ctl status` 全 run。期间 `users/sign_in` 会 502/500，healthcheck 会自己等到通为止，别急着判失败。

**Q：初始密码文件过期（24h）了进不去？** 账号还在，重置即可：`docker exec -it gitlab gitlab-rake 'gitlab:password:reset[root]'`。

**Q：限额写 4500m，为什么 stats 显示 4.395GiB？** Docker 把 `m` 当 MiB：4500×1024²=4,718,592,000 字节，二进制读法是 4.395GiB、十进制读法是 4.72GB——同一数两种单位；stats 里的占用同理（3.004GiB=3.22GB）。

**Q：macOS 上脚本莫名报 `substring expression < 0`？** 系统自带 bash 3.2 不支持 `${var:0:-3}` 负向子串，用 `${var:0:${#var}-3}` 等价改写（`gitlab_up.sh` 里已埋了一处活例）。

**Q：想把平台彻底重来？** `./gitlab_up.sh clean` 删容器和数据卷，再 `up` 即全新实例——项目 2 起的所有仓库/密钥会一起没掉，先想清楚。
