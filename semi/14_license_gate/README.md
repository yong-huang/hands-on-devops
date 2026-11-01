# 14 · License 门禁：EDA 许可证并发管控

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 14 · 阶段四「回归农场」
> license-mock 令牌服务（池 3 + TTL 兜底回收）+ with_license.sh 检出/归还包装器 + CI job 接入
> 验收在 `license_gate.sh verify`：4 路并发 3+1 排队 / kill -9 后 TTL 自动回收，全过打 `[ok]`

## Background

EDA 仿真器按**并发数**卖 License（FlexLM 模式：买了 10 个 seat，第 11 个并发请求就排队）。

这对 CI 意味着：回归农场不能"来者不拒"——16 个种子 job 同时启动会把 License 池瞬间抽干。门禁的正确姿势是把"检出 License"包装进 job 生命周期：**检出→执行→归还（失败也归还）**，池满则排队。

本实验用 license-mock（令牌池=3，TTL=120s 兜底回收）模拟这套语义，并用 4 路并发 + kill -9 两个破坏性实验验证排队与回收。

## What

心智模型一句话：**License 是借据，不是配置——借了要还，跑了要追**。

| 组件 | 说明 |
|:---|:---|
| license-mock 容器（:28261） | `/acquire`（池空 429）`/release` `/status`；TTL 到期自动回收（sweeper 线程） |
| tools/with_license.sh | job 包装器：acquire（60s 轮询排队）→ 执行命令 → `trap release EXIT`（失败也归还） |
| license_gate job | rtl-gcd yml 里以 with_license 包装 cocotb 仿真，接 needs DAG |

验证方法：`./license_gate.sh verify` 两组破坏性实验；`./license_gate.sh status` 看池状态。

## When to Use

| 场景 | 做法 |
|:---|:---|
| EDA 工具按并发计费 | with_license 包装（本实验）；池大小=License seat 数 |
| 客户端异常退出 | 服务端 TTL 兜底回收（本实验 120s；FlexLM 真实行为一致） |
| 需要跨 runner 的全局并发 | License 服务是中心化的（本实验单实例），runner 农场全部指向它 |
| 想知道"谁占着 License" | /status 的 leases 列表带 holder 与 expires_in |

## Quick Start

前置：项目 8-11 完成（yml 生长链与规范克隆在位）。

```bash
./license_gate.sh up      # license-mock 上线（28261）+ license_gate job 推 main
./license_gate.sh verify  # 两组破坏性实验（约 6 分钟）
./license_gate.sh status  # 池状态
./license_gate.sh clean   # 删容器（job 定义保留）
```

`verify` 的真实输出（实测，全过）：

```
=====> [verify1] 4 路并发抢 3 令牌：3 立即获得，第 4 个排队等待
  [ok]   3 个令牌全部检出（available=0）
  [ok]   第 4 路在 with_license 内排队（日志含 lease wait）
  [ok]   4 路全部走完 检出→执行→归还 生命周期
=====> [verify2] kill -9 持租容器 → TTL 到期自动回收
  [ok]   kill 前持有中（available=2）
  [ok]   TTL 到期自动回收：available 回 3（无客户端 release）

[ok] 项目 14 全部验收断言通过
```

## How It Works

### trap EXIT：归还的可靠性来自 shell 语义

with_license.sh 的核心是 `trap release EXIT`——无论命令成功、失败还是被信号打断（SIGTERM），shell 退出前必执行 release。唯一兜不住的是 kill -9（进程直接蒸发）——这正是服务端 TTL 存在的理由：两层保障缺一不可。

### TTL sweeper：服务端的"坏账清理"

license-mock 起一个后台线程每 5 秒扫一次租约表，过期即回收并打日志（`lease xxx EXPIRED`）。验收②的时序：kill -9 后 available=2，120 秒后 sweeper 回收 → available=3——全程无客户端参与。

### 池满语义：429 与客户端排队

/acquire 在池空时返回 429（而非阻塞）——把"等多久"的决定权交给客户端（with_license 轮询 60s 超时）。这让服务端保持无状态、客户端可自定义排队上限。

## Pitfalls & Q&A

**坑 1：python:3.12-slim 没有 curl。** with_license 第一版用 curl 调 API，holder 容器直接 command not found——客户端一律用 urllib 写的 lic.py（CI 镜像与 holder 容器都有 python3）。

**坑 2：hit/占用判定必须在"事前"。** verify1 曾在容器启动 4 秒后查 available——有的容器还没来得及 acquire，断言读到 3。时序敏感的断言要么等齐（sleep + 重试），要么用日志内容（"lease wait"出现即证明排过队）。

**Q：为什么不用真 FlexLM？** FlexLM 是商业闭源软件，License 文件绑定 MAC。license-mock 复刻其令牌语义（池/检出/归还/超时回收），门禁逻辑层完全一致——换真 FlexLM 时只改客户端探针。

**Q：CI job 里 60s 等不到 License 怎么办？** with_license 退出码 2——job 红。更好的策略是 job 层 retry（GitLab `retry: 1`）或把池大小与 runner 并发对齐（本项目 16 路矩阵 vs 池 3 的矛盾在真实团队用"回归分批+夜间大池"解）。
