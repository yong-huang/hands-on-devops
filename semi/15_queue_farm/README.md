# 15 · HPC 队列对接：sbatch 语义的回归作业（选做攻坚·降级路线）

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 15 · 阶段四「回归农场」
> slurm-mock（1:1 复刻 sbatch/squeue/sacct/output 四端点 + FIFO 并发 2）+ queue_client.py 提交-轮询-取回
> 验收在 `queue_farm.sh verify`：sbatch 提交 / 队列状态可见 / 输出取回 / 并发上限排队，全过打 `[ok]`

## Background

真实半导体农场的算力入口不是 K8s 而是 **LSF/Slurm** 这类 HPC 队列：作业以脚本形式提交（sbatch）、排队（PENDING）、上节点跑（RUNNING）、查账（sacct）。

CI（GitLab）与 HPC 队列的关系是"两级调度"：CI 管"何时提交什么作业"，队列管"哪台机器什么时候跑"。本实验验证这条桥接链路。

**选做降级说明**（清单已预案）：真 slurm-wlm + Munge 在 16G VM 的环境链过长（构建+密钥+守护进程三重坑）。slurm-mock 1:1 复刻四个端点的语义——**学习目标是"提交-轮询-取回"的作业模式**，换真 Slurm 时只改 queue_client.py 一层。

## What

心智模型一句话：**CI 提交的是"作业单"，队列回的是"取餐号"——两级调度各管各的**。

| 端点 | Slurm 对应 | 语义 |
|:---|:---|:---|
| POST /sbatch | sbatch | 提交脚本，返回 job_id |
| GET /squeue | squeue | PENDING/RUNNING 作业列表 |
| GET /sacct?job_id= | sacct | 作业终态与退出码（COMPLETED/FAILED） |
| GET /output?job_id= | cat slurm-*.out | 作业 stdout 取回 |

验证方法：`./queue_farm.sh verify`（提交-轮询-取回 + 并发上限排队两组）。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 农场算力在 HPC 队列上（半导体常态） | CI job 内 sbatch 提交 + 轮询 + 取回（本实验桥接模式） |
| 作业不 block 主线 | queue_regression 设 `allow_failure: true`（HPC 旁路作业语义） |
| 真 LSF/Slurm 环境 | 换 queue_client.py 的四个调用为目标系统 CLI（语义 1:1） |
| 队列过载保护 | 客户端 timeout + allow_failure（本实验） |

## Quick Start

前置：项目 12 完成（run_regression.py 在 rtl-gcd 里）。

```bash
./queue_farm.sh up      # slurm-mock 上线（28262）+ queue_regression job 推 main
./queue_farm.sh verify  # 提交-轮询-取回 + 并发上限（约 2 分钟）
./queue_farm.sh status  # 队列现状
./queue_farm.sh clean   # 删容器
```

`verify` 的真实输出（实测，全过）：

```
=====> [verify] 队列提交-轮询-取回（4 作业并发 2 → 排队可见）
  [ok]   sbatch 提交成功（job id 返回）
  [ok]   轮询捕获到 PENDING/RUNNING 状态（队列调度可见）
  [ok]   作业输出完整取回（COMPLETED）
=====> [verify2] 并发上限：4 作业提交时 squeue 可见排队
  [ok]   并发上限生效：RUNNING=2 + PENDING 排队

[ok] 项目 15 全部验收断言通过
```

## How It Works

### 两级调度的职责切分

GitLab runner 领到 CI job 后，job 内部把真正的计算以脚本形式 sbatch 给队列——CI job 只负责"提交与确认"，队列负责"算力分配"。

这样 CI 的 runner 并发（项目 5 的 concurrent）与队列并发（本实验 MAX_RUNNING=2）**互不干扰**，各自按自己的资源瓶颈调优。

### FIFO + 并发上限

slurm-mock 的调度线程每 0.5s 扫一次 PENDING 队列，空位（MAX_RUNNING-RUNNING）按 FIFO 补位。验收②利用"4 作业 vs 2 并发"的确定性排队观测 PENDING——与 P7 的 Pod Pending 同构，HPC 语境的排队更"显式"（squeue 直接可查）。

## Pitfalls & Q&A

**Q：为什么 CI job 设 allow_failure: true？** HPC 旁路作业（增量验证种子 21-24）失败不应 block 主线——主线由 P12 的矩阵把守。生产里这类"队列作业"通常还配独立的通知通道。

**Q：作业超时怎么办？** queue_client 600s 客户端超时（exit 2）；slurm-mock 侧也有 300s 强杀——两级超时与真 Slurm 的 `--time` 一致。

**Q：真 Slurm 下最常见的第一坑？** Munge 密钥不一致导致 sbatch 直接拒——这就是本实验模拟器规避的环境链。桥接代码（queue_client）不变，环境坑留在真实集群上解决。
