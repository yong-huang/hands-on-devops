# 09 · 单元仿真流水线：cocotb + JUnit 上 MR 测试 Tab

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 9 · 阶段三「第一条芯片流水线」
> unit stage：cocotb 2.x runner + iverilog 跑 tb_gcd，JUnit 报告进 MR 测试 Tab
> 验收在 `unit_sim.sh verify`：注错→红 + failure 指向用例→修复→绿（tests=1 failures=0）

## Background

Lint 拦得住"写错了"，拦不住"逻辑错了"。单元仿真回答"这个模块行为对不对"——项目 3 的 tb_gcd（6 组向量）在本地跑通过，本实验把它搬进流水线：MR 上每个提交自动仿真，结果以 JUnit 报告进 MR 测试 Tab，谁红、为什么红，一目了然。

## What

心智模型一句话：**cocotb 的 results.xml 就是 MR 测试 Tab 的数据源**。

unit job 的三件事：跑 `python3 sim/run_tests.py`（cocotb runner：iverilog 编译 gcd + 执行 tb_gcd）→ 产出 `sim/results.xml`（xunit 格式）→ `artifacts:reports:junit` 交给 GitLab 渲染。

验证方法：`./unit_sim.sh verify` 走注错-修复循环。

## When to Use

| 场景 | 做法 |
|:---|:---|
| MR 页面看"哪个用例挂了" | JUnit report（本实验）；failure 的 classname/name 直接指向用例 |
| 仿真失败但想保留证据 | `when: always` 让失败 job 也上传报告与波形 |
| 想并行不串行 | lint 与 unit 无依赖，各自独立跑（P11 才用 needs 排 DAG） |

## Quick Start

前置：项目 8 完成（规范克隆与 lint stage 在位）。

```bash
./unit_sim.sh up       # 推送含 unit stage 的 .gitlab-ci.yml（内容比对幂等）
./unit_sim.sh verify   # 注错→红 + JUnit→修复→绿（约 5 分钟）
./unit_sim.sh status   # 最近流水线
```

`verify` 的真实输出（实测，全过）：

```
=====> [demo] 注错 → unit 必须红 + JUnit failure 指向用例
  [ok]   注错 MR 的 unit job 红（pipeline #106 failed）
  [ok]   JUnit：tests=1 failures=1，failure 精确指向 smoke_gcd
=====> [demo] 修复 → unit 全绿
  [ok]   修复后 MR 流水线全绿（pipeline #107 success）
  [ok]   JUnit：tests=1 failures=0（MR 测试 Tab 数据可拉取）

[ok] 项目 9 全部验收断言通过
```

注错方式：把 tb 期望值 `gcd(48,18)=6` 翻转成 7——失败点精确落在 smoke_gcd 用例；修复 = `git checkout main -- tb/tb_gcd.py` 从主线还原。

## How It Works

### cocotb 2.x runner 与 GitLab 的握手

runner.test 把 xunit 写到 results.xml；GitLab 的 junit report 兼容 xunit schema，`testsuite` 的 tests/failures 属性直接变成测试 Tab 的计数。

冒烟断言（P3 埋的"成败只能看 results.xml"）在 CI 里同样成立：仿真 import 失败时 runner 返回 0，报告才是真相。

### report 类 artifact 的 zip 盲区（同 P8）

junit report 也不进 `/artifacts` zip——`paths: [sim/results.xml]` 双写后，验收脚本才能从归档解析 tests/failures。规则记死：**reports 给 UI，paths 给 API**。

### 注错的设计

翻转期望值（而非 RTL）是最小注错：RTL 是 SUT 不该被实验污染，tb 是"验证程序"，动它就是模拟"验证错了"——真实团队最常见的红。

## Pitfalls & Q&A

**Q：为什么 unit 与 lint 用 needs: [] 之外还各跑各的？** 本实验两者独立（并行省时）；P11 的集成点会用 needs 把它们串成 DAG——顺序是"先能跑，再编排"。

**Q：results.xml 为什么在 sim/ 子目录？** cocotb runner 的 results_xml 参数以 run_tests.py 的锚路径解析；junit 路径必须与工作区相对路径一致（`sim/results.xml`）。

**Q：iverilog 在 eda-base 里吗？** 在——06 构建镜像时四件套齐装，这正是"环境契约"的红利：job 不装任何东西。
