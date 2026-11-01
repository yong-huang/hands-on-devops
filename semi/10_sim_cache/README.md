# 10 · 编译仿真与缓存：verilator --cc 产 C++ 模型 + RTL 哈希缓存

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 10 · 阶段三「第一条芯片流水线」
> sim stage：verilator --cc --exe 编译 C++ 仿真模型，cache key 锁 RTL+TB 哈希，波形不进归档
> 验收在 `sim_cache.sh verify`：run1 MISS 实编译 / run2 HIT 0 秒 / 归档 < 10MB，全过打 `[ok]`

## Background

cocotb 仿真（P9）每条流水线都从零编译——RTL 不变时这是纯浪费。工业界解法是**编译缓存**。

verilator `--cc --exe --build` 产出 C++ 编译模型（obj_dir），按"RTL+TB 的内容哈希"作缓存键：RTL 变了 key 变（缓存自然失效），没变则直接复用。

本实验同时验证第二件事：仿真的**大波形绝不进归档**——一条 20MB 的 wave.vcd 就能让 artifact 存储爆炸。

## What

心智模型一句话：**cache key = 源文件指纹，obj_dir = 指纹对应的免费午餐**。

| 机制 | 配置 |
|:---|:---|
| 缓存键 | `cache: key: files: [rtl/gcd.v, sim/tb_main.cpp]` |
| 缓存内容 | `paths: [sim/obj_dir]`（编译产物 C++ 模型） |
| 归档瘦身 | `artifacts: exclude: [sim/wave.vcd]`（20MB 假波形只留 runner 本地） |
| 命中证据 | sim_meta.json：`cache_hit=… compile_seconds=…`（hit 在编译前判定！） |

验证方法：`./sim_cache.sh verify`——先改 tb_main.cpp 触碰缓存键（保 run1 是 MISS）。

然后跑两条流水线对比 compile_seconds，再查归档体积。

## When to Use

| 场景 | 做法 |
|:---|:---|
| RTL 不变的重复流水线 | 本实验：files 哈希键，自动命中 |
| RTL 微改后的全量重编译 | files 变 → key 变 → 自动 MISS（这正是想要的语义） |
| 波形/日志超大 | artifacts exclude（本实验）；或 expire_in 缩短保留期 |
| 跨 runner 共享缓存 | 默认 cache 在 runner 本地卷；分布式要看对象存储 cache 配置 |

## Quick Start

前置：项目 8/9 完成（.gitlab-ci.yml 生长链在位）。

```bash
./sim_cache.sh up      # 推送含 sim stage 的 yml + sim/tb_main.cpp
./sim_cache.sh verify  # bust→run1(MISS)→run2(HIT)→归档检查（约 8 分钟）
./sim_cache.sh status  # 最近流水线
```

`verify` 的真实输出（实测，全过）：

```
=====> [bust] 缓存键变更（改 tb_main.cpp 触碰 cache key.files）——bust 流水线即 run1（MISS+实编译）
  [ok]   run1 success（pipeline #133）
  [  =] run1 meta: cache_hit=false compile_seconds=4
=====> [run2] 第二条流水线（预期 cache HIT，compile_seconds≈0）
  [ok]   run2 success（pipeline #134）
  [  =] run2 meta: cache_hit=true compile_seconds=0
=====> [verify] 验收① 缓存命中：compile_seconds 降 ≥70%
  [ok]   缓存生效：run2 HIT 且编译耗时降幅 ≥70%
=====> [verify] 验收② artifacts 归档 < 10MB（20MB 假波形被排除）
  [ok]   归档 0KB < 10MB（wave.vcd 被 exclude）

[ok] 项目 10 全部验收断言通过
```

诚实预期：缓存命中只省**编译**时间（gcd 模型 4 秒），仿真执行时间不变——真实工程里编译占 20-40 分钟时这就是 20 分钟的差；演示负载小，比值看语义不看绝对值。

## How It Works

### hit 判定必须在编译之前

`cache_hit` 的判定是 `[ -x obj_dir/Vgcd ]`——放在编译之后的话 Vgcd 恒存在，永远报 true（实测踩过）。次序：先判 hit 存快照 → 编译（仅当 MISS）→ 跑模型 → 写 meta。

### bust 流水线就是 run1

要演示 MISS 需要"缓存键变化后的第一条流水线"：改 tb_main.cpp 内容（追加一行注释）即变更 key。

但**这次 push 自己触发的流水线就是 MISS+实编译的那条**——此前把它当准备步骤，MISS 被消耗、对比跑成 HIT/HIT。测量设计：bust 提交=run1，空提交=run2。

### 演示分支不匹配 rules 的空流水线

job rules 只放行 merge_request_event 与 main——演示分支 push 出的流水线 **0 jobs 直接 failed**。缓存对比改在 main 上用空提交做，或 rules 加分支白名单。

## Pitfalls & Q&A

**Q：为什么 run2 的 compile_seconds 是 0 而不是缓存回放的时间？** 缓存恢复的是编译产物（obj_dir 二进制），编译步骤整个跳过。

0 是真实语义，不是测量误差。

**Q：cache 存在哪里？** runner config 的 `volumes = ["/cache"]` 本地卷（单 runner 生效）；多 runner 农场要配 S3/MinIO 分布式缓存，否则每个 runner 冷启动各编译一次。

**Q：为什么 artifacts zip 里 20MB 的 wave.vcd 不见了？** `artifacts:exclude` 在归档打包时剔除——波形只存在于 runner 工作目录（下一个 job 不可见），这正是"调试产物本地留、归档只传结论"的用法。

**Q：cache 会不会把脏 obj_dir 还原进来？** 会——这就是 key 里必须含 tb_main.cpp 的原因：驱动变了旧二进制就不匹配。

本实验 tb_main.cpp 既是 key 文件又是编译输入，语义自洽。
