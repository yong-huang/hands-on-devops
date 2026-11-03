# 25 · 集成点③：合规流水线——三道门真进 CI

> 22 的策略门、23 的安全门/密钥门，真实接进 20 的 Gitea Actions：四类 push 实证"合规全绿、违规红"，权威状态源断言（Gitea DB）。

## Background

22/23 在本地跑通了门禁命令，但"门禁"只有在 **CI 里**才叫门禁——本地 `|| true` 的演示可以绕过，pipeline 的非零退出码不能。本实验把三道门写成 workflow 步骤（conftest → trivy → gitleaks 串行），用四类 push 实证：合规变更畅通，三类违规分别被对应门拦下（run status=Failure）。与 20 的关系：复用其 Gitea+act_runner 基建模式；差异在 job 镜像（工具三件套）与断言场景。

## What

- `citools/`：job 工具镜像（python:3.11-slim + node + conftest/trivy/gitleaks 二进制——**从官方工具镜像 docker cp 抽取**）
- `repo-seed/`：声明源（合规/违规 manifests、合规/违规 IaC、明文口令）+ 三道门 workflow
- `compliance_pipeline.sh` 四相：up（镜像+Gitea+runner）/ green（合规 push → Success）/ red（三类违规 → Failure×3）/ clean

## When to Use

- 组织要落地"三道门"：策略（OPA）+ 安全（IaC 扫描）+ 密钥（泄漏扫描）在 merge 前全过
- 验证门禁有效性：不只测"绿能过"，更要测"坏必拦"（本实验的 red 相就是门禁自身的测试）

## Quick Start

```bash
cd labs/25_compliance_pipeline
./compliance_pipeline.sh all    # 四相：up → green → red×3 → clean（约 6 分钟）
```

前置：docker；三件套**不需要本机安装**（从官方工具镜像抽取，见 Pitfalls 4）。

## How It Works

### 三道门的 workflow（串行，任一红即全链阻断）

```yaml
steps:
  - uses: actions/checkout@v4        # 没有它 workspace 是空的（Pitfalls 1）
  - run: conftest test manifests/ -p policies/          # gate1 策略门
  - run: trivy config --severity HIGH,CRITICAL --exit-code 1 iac/   # gate2 安全门
  - run: gitleaks detect --no-git -c .gitleaks.toml --source .      # gate3 密钥门
```

四类 push 场景（每次 push 触发一个 run，`repo-seed` 按场景裁剪文件）：
| 场景 | 推入内容 | 预期 | 实测 |
|:---|:---|:---|:---|
| green | 合规 manifest + 合规 IaC | Success | ✅ 三门全过 |
| red-policy | + 违规 manifest（:latest） | Failure（gate1） | ✅ |
| red-iac | + 全开安全组 TF | Failure（gate2） | ✅ |
| red-secret | + 明文口令默认值 | Failure（gate3） | ✅ |

### 权威状态源（沿用 20 的修复）

`docker exec lab25-gitea sqlite3 /data/gitea/gitea.db "SELECT status FROM action_run ..."`——act_runner 的结果不落 stdout；DB status 字典 1=Success 2=Failure。**wait 循环的进度行必须打 stderr**：命令替换 `$(wait_run ...)` 会把 stdout 一起捕获，混行导致状态解析恒失败（实测）。

## Pitfalls & Q&A

1. **Gitea Actions 不自动拉源码**：job 容器 workspace 起步为空，没有 `actions/checkout` 时 `manifests/` 直接 `stat: no such file`（实测）。checkout 是 JS action → 需要 **node**（python-slim 镜像没有，apt 装）。
2. **GITEA_INSTANCE_URL 必须用宿主可路由地址**（网桥网关 IP）而非容器名：act_runner 创建的 job 容器默认 **host 网络**，解析不了 lab-net 里的容器名——checkout 的 `git fetch origin` 三次重试失败实测。
3. **github release 直下会被截断/限速**（20MB 的 trivy 4 轮重试都断，`-C -` 续传还可能越追加越大）——改从 **Docker Hub 官方工具镜像 docker cp 抽二进制**（daemon 镜像源对中小镜像可用）：`aquasec/trivy` / `zricethezav/gitleaks:v8.30.1`（tag 必须带 v）/ `openpolicyagent/conftest`（二进制在镜像**根路径** /conftest，usr/local/bin 下是坏 symlink）。
4. **JS action 需要 node**：act 报 `node: executable file not found` 即此因；debian 源换 TUNA 后 `apt-get install nodejs`（18.x，兼容 act_runner 要求的 node20 执行器语义）。
5. **gitleaks 的 `--report-path /dev/stdout` 报 `Unknown report format`**——直接终端输出即可，别配 report-path。
6. 本机 conftest --version 显示 "dev" 无妨，job 镜像里用 release 版 v0.62.0。

## 产物清单

- `citools/Dockerfile`（node + 三件套抽取）+ `compliance_pipeline.sh`（四相，四场景断言全绿）
- `repo-seed/`（manifests/iac/workflow/.gitleaks.toml）+ `policies/`（22 的 Rego 策略拷贝）
- 运行时：lab25-gitea/runner 容器与 volume 全部随 clean 销毁
