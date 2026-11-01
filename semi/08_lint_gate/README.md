# 08 · Lint 门禁：verilator 把住 MR 第一道关

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 8 · 阶段三「第一条芯片流水线」
> rtl-gcd 装上 .gitlab-ci.yml：verilator -Wall 告警即红，告警转 Code Quality 上 MR widget
> 验收在 `lint_gate.sh verify`：注错→lint 红+codequality 可拉取→修复→全绿，全过打 `[ok]`

## Background

RTL 的 bug 上了主线，仿真才能抓到——那是几百倍的成本。Lint 是把这类低级错误拦在 MR 阶段的第一道闸：verilator `--lint-only -Wall` 纯静态分析，秒级出结果。

本实验给 rtl-gcd 装上第一段 `.gitlab-ci.yml`（后续实验逐段生长成全流水线），并把告警转成 GitLab 的 Code Quality 报告——MR 页面直接看到"哪一行有什么问题"。

## What

心智模型一句话：**lint 输出是原料，Code Quality JSON 是 GitLab 的"通用告警汇率"**。

| 产物 | 说明 |
|:---|:---|
| `.gitlab-ci.yml` 的 lint job | `verilator --lint-only -Wall rtl/*.v`，跑在 eda-base:1.0（06 的契约镜像） |
| `tools/verilator2codequality.py` | 按 `%Warning-XXX: path:line: msg` 解析，转 GitLab codequality JSON（fingerprint=sha256(path:line:msg)，供 widget 做"新增/已修复" diff） |
| 门禁语义 | codequality 条数 > 0 → exit 1（红） |

验证方法：`./lint_gate.sh status` 看最近流水线；`./lint_gate.sh verify` 走一遍完整注错-修复循环。

## When to Use

| 场景 | 做法 |
|:---|:---|
| MR 上可视化"新增了哪些告警" | codequality report + fingerprint（本实验） |
| 只想红绿不想 UI | 门禁 exit code 就够 |
| 告警分级行情 | severity 字段可按 %Warning 类型映射（major/minor） |
| 老仓库存量告警 | 先 baseline（把存量 fingerprint 记账，只拦新增）——本实验仓库是干净的，直接零容忍 |

## Quick Start

前置：项目 3/5/6 完成（载体、runner、eda-base 镜像在位）。

```bash
./lint_gate.sh up      # 克隆规范副本 → 装 .gitlab-ci.yml → 推 main
./lint_gate.sh verify  # 注错→红+上报→修复→绿（约 5 分钟）
./lint_gate.sh status  # rtl-gcd 最近流水线
./lint_gate.sh clean   # 关演示 MR、删演示分支（门禁保留）
```

`verify` 的真实输出（实测，全过）：

```
=====> [demo] 注错 → MR → lint 必须红 + codequality 上报
  [ok]   注错 MR 的 lint job 红了（pipeline #98 failed）
  [ok]   codequality.json 可从 API 拉取且含 3 条告警
=====> [demo] 修复 → lint 必须绿
  [ok]   修复后 MR 流水线全绿（pipeline #99 success）

[ok] 项目 8 全部验收断言通过
```

诚实预期：verify 每轮会新建一个 lint-demo-bug MR（旧的自动随分支删除关闭）；"等待流水线"按 **commit SHA 精确匹配**——按"最新流水线"查会被 auto-cancel 竞态坑（实测 A 被 B 取消导致误判 canceled）。

## How It Works

### codequality 报告的双写

`artifacts:reports:codequality` 让 MR widget 渲染告警，但 report 类 artifact 存在独立通道——`/jobs/:id/artifacts` 的 zip 里**只有 paths 列表的文件**，单文件下载路由还实测 404。

解法：`paths: [lint.log, codequality.json]` 双写——报告给 UI，归档给 API，两边都有。

### 门禁按"条数"不按"文件大小"

干净 lint 的 codequality.json 是 `[]`——3 字节、`[ -s ]` 为真。门禁必须解析 JSON 数条数（`len(json.load(...))`），文件大小语义在这里是反的。

### MR 流水线的触发与等待

rules 用 `$CI_PIPELINE_SOURCE == "merge_request_event"` 让流水线跟着 MR 走（branch push 也会触发 main 流水线）。

等待用 `GET pipelines?sha=<commit>` 精确锚定——auto-cancel 冗余 MR 流水线的默认行为会让"查最新"读到一个刚被取消的旧流水线。

## Pitfalls & Q&A

**坑 1：job Pod 里拉 LFS 大文件失败。** GitLab 向 job 广播的 LFS 端点是它自己的 external_url（http://localhost:28200）——Pod 内 localhost 是 Pod 自己。

lint 不需要大文件，`.gitlab-ci.yml` 全局 `GIT_LFS_SKIP_SMUDGE: "1"`（需要大文件的 job 再显式 `git lfs pull`）。

**坑 2：bash 3.2 的 local 同行多赋值不保证从左到右。** `local pid="$1" iid="$2" ref="...$iid..."` 在第三个赋值里引用 $iid → set -u 直接 unbound（bash 4+ 才顺序生效）。拆成三行 local。

**坑 3：git-lfs 往 stdout 喷 "Deleted 'branch...'"。** 连 `push -q` 都拦不住（是 lfs 钩子的输出）。凡 `$(...)` 捕获 git 输出的地方，解析都取**最后一行**或重定向 `/dev/null`。

**Q：为什么用 merge_request_event 而不是只在 branch push 上跑？** 门禁的语义是"这个 MR 合入后会不会红"——MR 流水线把 source+target 合并结果当被测对象，比纯分支流水线更接近事实。

**Q：告警 3 条都是什么？** 未驱动信号（UNDRIVEN）+ 声明文件名不匹配（DECLFILENAME，模块名与文件名不一致）——都是真实告警，修复=整块删除演示模块（UNUSED/DECLFILENAME 靠"赋个初值"清不掉）。
