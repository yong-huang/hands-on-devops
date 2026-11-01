# 03 · rtl-gcd 载体入库：Git-LFS 大文件治理

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 3 · 阶段一「入职第 1 周——把半导体内网立起来」
> 建立后续 20 个项目的 SUT（被测系统）：GCD IP 载体——RTL 电路源码（Register Transfer Level）、cocotb TB 验证脚本（testbench）、仿真入口——2GB 假 PDK/GDS/波形走 LFS 入库
> 全部断言在 `rtl_lfs.sh verify`：LFS 实体 / SKIP_SMUDGE 零下载 + pull 补全 / 新 100MB 走 LFS，全过打 `[ok]`

## Background

芯片仓库和互联网仓库有个本质差异：PDK 工艺库（几百 MB 的 .lib）、版图（GB 级 .gds）、回归波形动辄远超 git 的舒适区。git 对大文件的处理方式是把整个文件按版本存进对象库——几个人改几版 PDK，`.git` 就膨胀到谁都 clone 不动。

Git-LFS（Large File Storage，git 的大文件旁路）的思路：仓库里只放 ~130 字节的**指针文件**（记录 oid，即内容的 sha256 对象 ID），真实内容存到旁边的 LFS 对象存储，clone 时按需下载（把指针换出实体的检出过程叫 smudge）。

上一项目装的门禁（>50MB 直推拒绝）把 LFS 从「最佳实践」变成了「硬性要求」——本实验重现一个塞满大文件的历史仓库，让它撞门禁，然后用 `git lfs migrate` 重写历史自救。

## What

心智模型一句话：**git 仓库只管指针，LFS 仓库管实体**。`rtl-gcd` 项目结构：

```
semi/ip/design/rtl-gcd
├── rtl/gcd.v          # 欧几里得减法 GCD，valid/ready 双向握手（SUT 本体）
├── tb/tb_gcd.py       # cocotb 冒烟 testbench（6 组向量）
├── sim/               # runner 入口 run_tests.py + Makefile 薄封装
├── docs/              # 接口约定
├── pdk/fake_pdk.lib   # 640MB 假 PDK（LFS）
├── gds/fake.gds       # 960MB 假 GDSII（LFS）
└── waves/wave.vcd     # 480MB 假波形（LFS）
```

三条通道各走各的：小文件走 git 对象；`*.lib/*.gds/*.vcd` 走 LFS 指针；`>50MB 未 track`（没经 `git lfs track` 声明托管）`的裸 blob` 走到 pre-receive（02 装的服务端门禁钩子）就被弹回。

验证方法：`./rtl_lfs.sh status` 看 LFS 存储体积，`git lfs ls-files` 看每个文件的指针/实体状态。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 接手历史仓库，大文件已进 git 历史 | `git lfs migrate import --everything --include=<模式>` 重写全部历史（本实验主角） |
| 新仓库，一开始就知道哪些是大文件 | 先 `git lfs track "<模式>"` 再提交，根本不用 migrate |
| 只想瘦身某些目录 | migrate 的 `--include/--exclude` 按路径模式过滤 |
| 浅需求：只是 clone 慢 | 不动历史，`GIT_LFS_SKIP_SMUDGE=1` 秒级 clone + 按需 `git lfs pull` |

## Quick Start

前置：项目 1/2 完成（`../01_gitlab_up` 平台在线、`../02_org_guard` 组树与门禁在位，依赖 python-gitlab/pyyaml）。

`brew install git-lfs iverilog` + `pip install cocotb`——git-lfs 是独立 formula（macOS 自带 git 不含），后两者为冒烟仿真用。

磁盘提示：峰值约 8GB——2GB 负载会在本地仓库（.work 约 6.5GB）、GitLab LFS 存储、verify 的两个临时 clone 各存一份，小磁盘先看一眼 `df -h`。

```bash
./rtl_lfs.sh up      # 建仓库 → 直推被拒（演示）→ track/migrate → LFS push → 仿真冒烟
./rtl_lfs.sh verify  # 三条验收断言
./rtl_lfs.sh status  # 项目 / LFS 存储体积 / 指针清单
./rtl_lfs.sh clean   # 删项目与本地副本（组树门禁保留）
```

`up` 的关键输出（2026-10-29 实测，节选）：

```
=====> [demo] 裸大文件直推 → 平台门禁必须拒绝（02 的 hook 首战）
  [ok]   直推被 pre-receive 拒绝（输出见 .work/rtl-gcd/first_push_rejected.log）
         remote: [pre-receive] 拒绝：refs/heads/main 引入超大文件 gds/fake.gds（960MB > 50MB）
         remote: [pre-receive] 大文件请走 LFS：git lfs track "<模式>" 后重新提交（指针仅 ~130B，不受此限制）

=====> [lfs] LFS 治理：track 规则 → migrate 重写全部历史 → 重推
Updating refs: ..., done.
Uploading LFS objects: 100% (3/3), 2.1 GB | 0 B/s, done.
  [ok]   LFS 指针推送成功（大对象走 LFS 通道入库）

=====> [smoke] 载体自证：iverilog 编译 + cocotb 冒烟仿真
         smoke: tests=1 failures=0 errors=0
  [ok]   6 组向量仿真全过（gcd SUT 活着）
```

`verify` 的真实输出（2026-10-29 实测，节选；样本是第二次 verify——已含验收③累计的 wave_100m.vcd，fresh 重放为 3 个）：

```
=====> [verify] 验收① git lfs ls-files：全部假大文件均为 LFS 指针
         d4dac90aec * pdk/fake_pdk.lib
  [ok]   全部 4 个大文件均为 LFS 实体（第二列 * 前缀）
=====> [verify] 验收② GIT_LFS_SKIP_SMUDGE 秒级 clone + git lfs pull 补全
         全量 clone（含 LFS ~2GB）: 3.33s / SKIP_SMUDGE clone: 0.49s
  [ok]   SKIP_SMUDGE clone 的 .git/lfs 为空（0 个对象被下载）
  [ok]   git lfs pull 补全成功（fake.gds 回到 960MB 实体）
=====> [verify] 验收③ 新 100MB 波形走 LFS push 成功（门禁放行 LFS 指针）
  [ok]   100MB 文件经 LFS 入库成功（hook 见到的只是 ~130B 指针）

[ok] 项目 3 全部验收断言通过
```

诚实预期：`up` 每次重放全流程（远端有旧内容会先重置项目），2GB 负载生成+上传约 1 分钟；耗时比是**参考值**不是断言——localhost 近内存速度下 skip-clone 基线噪声大（实测 1.9x-7.6x 波动），结构性事实（`.git/lfs` 零下载）才是本义。

## How It Works

### migrate 重写历史：把"指针化"做成手术

`git lfs migrate import --everything --include="*.lib,*.gds,*.vcd"` 遍历所有 ref（分支/标签引用）的所有提交，把匹配模式的 git blob 换成 LFS 指针、原 blob 移入 `.git/lfs/objects`。

然后**重写每一个包含该文件的提交**（SHA 全变）。

所以 migrate 必须在 push 前做——本实验的顺序是：本地先造"历史遗留"（大文件进 git 对象）→ 直推被门禁拒 → migrate 重写 → 重推全是指针。

若历史已推上远端，migrate 后要 `git push --force` 并通知全组重新 clone。

### 指针文件与三态标记

指针是 134 字节的文本：`version + oid sha256 + size`。

`git lfs ls-files` 每行三段：`<oid> <*|-> <路径>`——第二列 `*` 表示实体已 checkout 到工作区，`-` 表示还是指针（skip-clone 后全是 `-`）。

实测有个坑：migrate 自称 "Checkout: done" 但工作区仍是指针，需要显式 `git lfs checkout` 补一次（up 里已内置）。

### SKIP_SMUDGE 的正确度量

`GIT_LFS_SKIP_SMUDGE=1` 只影响 clone 时的 smudge 过滤器——git 对象照常下载，LFS 实体一个不拉。

所以它的结构特征是 `.git/lfs/` 为空，之后 `git lfs pull` 按需补全。

耗时比在本机/小负载下会失真：skip-clone 基线（git clone 本身）在 0.5-1.6s 间漂移（实测 0.55-1.58s），同负载下比值能从 3.4x 摆到 7.6x，早期 260MB 负载下甚至只有 1.9x——**断言应该盯"下载了 0 个 LFS 对象"，而不是盯秒表**。

### 冒烟仿真：runner API 与退出码陷阱

cocotb 2.x 移除了 Makefile.sim 流程，runner 拆到 `cocotb_tools.runner`（不是 `cocotb.runner`）。

tb 在 `tb/` 目录，要把该目录**插进本进程 sys.path** 才能被仿真进程 import——runner 会用当前进程 sys.path 重写子进程 PYTHONPATH，extra_env 反而不生效。

最大的坑：cocotb 2.1.0 的 `runner.test()` 在仿真器 import 失败时**仍返回 0**。

成败只能解析 `results.xml` 的 testsuite 属性（`rtl_lfs.sh` 与 `run_tests.py` 都做了这一层）。

## Pitfalls & Q&A

**坑 1：migrate 语法。** 模式匹配走 `--include="*.a,*.b"`（逗号分隔），位置参数是 ref 不是模式。

`--everything` 与显式 ref 互斥；裸写 `-- "*.lib"` 会报 "Cannot use --everything with explicit reference arguments"。

**坑 2：没写 `timescale` 的 RTL 在 Icarus 里跑不了 cocotb 时钟。** 报 "Bad period: Unable to accurately represent 10(ns) with simulator precision of 1e0"——Icarus 默认精度 1 秒。

RTL 文件头补 `` `timescale 1ns/1ps ``（本就该写）。

**坑 3：`.work` 是 scaffold 的拷贝。** 改了 `scaffold/sim/run_tests.py` 直接重跑 `.work` 里的旧文件等于白改。

调载体内容一律改 `scaffold/` 再 `up`（会重放全流程）。

**Q：为什么 rtl-gcd 的 main 保护是 push=40 而 push-lab 是 0？** SUT 仓库后续要被 CI（root 身份）直推 tag 和分支（项目 8 起），push=0 会把 CI 也挡死。

Maintainer 可直推、dev1 无权，纪律与工程两全。

**Q：假文件为什么是 2GB 这么夸张？** 刻意为之：本机 localhost 传输近内存速度（实测数百 MB/s 量级），260MB 负载的全量 clone 和 skip-clone 拉不开差距（实测 1.9x），2GB 才让 LFS 传输占主导。

真实半导体仓库的 PDK/GDS 本就以 GB 计，不算失真。

**Q：verify 每跑一次就多一个 100MB 的 wave_100m.vcd？** 是的，验收③是真实 push，LFS 存储会累计。

介意体积就 `./rtl_lfs.sh clean && ./rtl_lfs.sh up` 重放（代价是 1 分钟重建）。
