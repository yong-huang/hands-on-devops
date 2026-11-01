# 06 · EDA 标准执行镜像：工具链不可变交付

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 6 · 阶段二「Runner 农场与执行环境」
> 启用 GitLab Container Registry（28250）→ 构建 eda-base:1.0（verilator/yosys/iverilog/cocotb）→ 推送 → CI job 引用 + 断网拉取证明
> 验收①②在 `eda_image.sh verify`：镜像冒烟四版本 / 删本地镜像后 job 从 Registry 拉起并回填

## Background

"在我机器上能仿真"是硬件团队的经典事故。EDA 工具链（verilator/yosys/iverilog 的版本组合）就是环境本身——项目 5 的 runner 只是工人，本实验把工人的**工具箱**固化成镜像：`eda-base:1.0`。

此后所有 CI job 的环境由镜像 tag 锁定，升级 = 出新 tag + 改引用，而非"哪台 runner 顺手 apt install 了什么"。

镜像的住处是 GitLab 自带的 Container Registry——01 的平台扩展三件套（gitlab.rb 加配置、compose 加端口、reconfigure 生效），与 02 的 hooks 段同一演进模式。

## What

心智模型一句话：**镜像 tag 就是环境契约，Registry 就是契约档案室**。

| 产物 | 说明 |
|:---|:---|
| `localhost:28250/semi/eda-base:1.0` | ubuntu 24.04 + verilator 5.020 / yosys 0.33 / iverilog 12.0 / cocotb 2.1.0（全部国内源安装） |
| smoke-test.sh | 打印四工具版本，CI job 与验收共用（SMOKE_OK 收尾） |
| runner-lab 的 eda-smoke job | `image: localhost:28250/semi/eda-base:1.0` 的引用样板 |

验证方法：`./eda_image.sh status` 看 Registry 仓库与存储体积；`./eda_image.sh verify` 跑两条断言。

## When to Use

| 场景 | 做法 |
|:---|:---|
| CI 环境标准化（本实验） | 版本化基础镜像 + job 显式引用 tag |
| 升级工具链 | 构建新 tag（1.1）推 Registry → 灰度改 job 引用 → 回滚 = 改回旧 tag |
| 跨项目共享镜像 | 镜像挂独立项目（semi/eda-base）+ CI_JOB_TOKEN allowlist 授权消费方 |
| 公开分发 | 基础镜像项目设 public，Registry 匿名拉取（本实验的降级路径） |

## Quick Start

前置：项目 5 完成（runner 在线、runner-lab 在位）。

```bash
./eda_image.sh up      # 启用 Registry（重建容器+reconfigure，约 4 分钟）→ 构建+推送 → 加冒烟 job
./eda_image.sh verify  # 两条断言（①镜像冒烟 ②断拉取）
./eda_image.sh status  # Registry 仓库/存储/本地镜像
./eda_image.sh clean   # 删镜像项目与本地镜像（Registry 服务保留）
```

`verify` 的真实输出（实测，两条全过）：

```
=====> [verify] 验收① 冒烟 job 用 Registry 镜像打印四版本
  [ok]   eda-smoke #87 success（verilator/yosys/iverilog/cocotb 版本齐全）
         ... verilator: Verilator 5.020 (Debian 5.020-1)
         ... yosys: Yosys 0.33
         ... iverilog: Icarus Verilog version 12.0
         ... cocotb: 2.1.0
=====> [verify] 验收② 删本地镜像后，job 仍能从 Registry 拉起
  [  =] 本地镜像已删
  [ok]   job 从 Registry 拉起成功且本地镜像已回填（docker images 可见）

[ok] 项目 6 全部验收断言通过
```

诚实预期：up 首次启用 Registry 要**重建容器**（compose 加端口映射，数据卷无损，GitLab 就绪约 4 分钟）；镜像构建含 apt 全量工具链 + cocotb 源码编译（见坑 1），约 3-6 分钟。

## How It Works

### 平台扩展三件套（与 02 同模式）

gitlab.rb 追加 registry 段（幂等 grep）→ compose 追加 `28250:5050` → `docker compose up -d` 重建容器加载端口 → `gitlab-ctl reconfigure` 渲染 registry 配置。

`/v2/` 探活 401 = 鉴权态，正常。registry_nginx 监听 5050 + `listen_https=false`，与 HTTP-only 的 external_url 一致。

### 跨项目拉取的授权链

runner-lab 的 job 拉 eda-base 的私有镜像，走的是 **CI_JOB_TOKEN**——但默认只允许本项目镜像，跨项目要过 allowlist。

在镜像项目上 `POST /projects/:id/job_token_scope/allowlist`（target_project_id=消费方）；API 不可用时降级 public（匿名拉取）。

没授权的报错是 `pull access denied ... may require docker login`——与"镜像不存在"同文案，排查先查 allowlist 再查路径。

### pull 的执行层与幂等标记

镜像 pull 由**宿主 docker daemon**（runner 经 docker.sock）执行，`localhost:28250` 被 daemon 视为 insecure registry 自动走 HTTP。

断拉取测量的坑：①自己也会触发流水线，②若沿用 ① 的流水线基线，会把 ① 的旧 job 当成"② 的新证据"秒过——② 开头必须重取流水线基线（脚本已内置）。

## Pitfalls & Q&A

**坑 1：cocotb 在 linux-aarch64 没有预编译 wheel。** pip 拉 sdist 现场编译，需要 `build-essential` + `python3-dev`（缺 g++ 报 `aarch64-linux-gnu-g++ failed`）。

macOS 上能直接装 wheel 是因为 Apple Silicon 有 macosx 轮子——平台差异，Dockerfile 已内置。

**坑 2：buildx 默认 provenance 让 GitLab Registry 拒收。** push 报 `blob unknown to registry`。

原因：新版 buildx 附加 attestation 清单，GitLab 内置 distribution 吃不下。构建加 `--provenance=false`。

**坑 3：ProjectFile.decode() 返回 bytes。** python-gitlab 的文件对象 `decode()` 是 base64 解码出 bytes。

要再 `.decode("utf-8")` 才是字符串——顺序写反就是 `bytes + str` TypeError。

**Q：为什么镜像项目独立于 rtl-gcd？** 基础镜像的消费者是全部项目（runner-lab、后续 CI），挂在 rtl-gcd 下会让授权链反向耦合；独立项目 + allowlist 是标准的镜像分发结构。

**Q：端口怎么又变多了？** 28250 属于全系列 28200-28279 段（根 README 分配表已登记），Registry 与 28252（气隙 mirror，项目 22）是两个不同实例。

**Q：如何升级工具链？** 改 Dockerfile → `eda_image.sh up` 重推（同 tag 覆盖是坏味道，正式做法：新 tag 1.1 + job 引用切换）。本实验 tag 固定 1.0，重放 up 幂等。
