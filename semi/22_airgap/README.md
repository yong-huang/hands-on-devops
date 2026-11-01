# 22 · 气隙供给与镜像 mirror：内网自足演练

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 22 · 阶段六「生产化」
> 白名单镜像入私仓（28252/mirror:5000 双名）+ internal 网络隔离 runner + job 全绿
> 验收在 `airgap.sh verify`：私仓三类镜像 / 断网 runner 全绿 / 镜像来自 mirror:5000 / 内网可达，全过打 `[ok]`

## Background

半导体内网的铁律：构建环境不触外网——依赖全部来自**白名单私仓**。本实验把气隙做成 Docker 拓扑：`airgap-net`（internal 网络，无外网路由）上放 gitlab（别名）、mirror 私仓（别名）与 runner-offline；job 容器的镜像从 `mirror:5000` 私仓拉取。

## What

心智模型一句话：**气隙 = 拓扑隔离（internal 网络）+ 供给切换（镜像名从外网源改为 mirror:5000 别名）**。

| 组件 | 网络 | 作用 |
|:---|:---|:---|
| gitlab | compose + airgap（别名 gitlab） | 内网可达的服务端 |
| mirror-registry | compose + airgap（别名 mirror），发布 127.0.0.1:28252 | 私仓：宿主推送 28252，job 拉取 mirror:5000 |
| runner-offline | airgap | job 容器 network_mode=airgap-net，镜像白名单 |

验证方法：`./airgap.sh verify`——私仓清单核对 + 断网 runner 跑通探针 job（内网 200 + 镜像来自 mirror:5000）。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 构建环境不触外网 | internal 网络 + 私仓别名（本实验拓扑） |
| 依赖入库 | 白名单镜像经 daocloud 拉取重打标推 28252（宿主侧一次性动作） |
| 新依赖/新版本入内网 | 走审批后重跑 up 的镜像同步段（人肉 firewall） |

## Quick Start

前置：项目 5/6 完成（config.toml 模板与 eda-base:1.0 在位）。

```bash
./airgap.sh up       # mirror 私仓 + 白名单同步 + runner-offline 上线
./airgap.sh verify   # 私仓清单 + 断网 runner 探针
./airgap.sh status   # 私仓 catalog
./airgap.sh clean    # 删离线 runner
```

`verify` 的真实输出（实测，全过）：

```
=====> [verify1] 私仓清单核对：三类镜像（base/os/ci）在 28252
  [ok]   私仓含 semi/eda-base
  [ok]   私仓含 library/alpine
  [ok]   私仓含 gitlab/gitlab-runner
=====> [verify2] 断网 runner 跑通 lint+unit（内网通/外网断双断言）
  [ok]   断网 runner 全 job 绿
  [ok]   镜像供给来自私仓 mirror:5000（非外网）
  [ok]   内网可达断言（gitlab 页面 200）

[ok] 项目 22 全部验收断言通过
```

## How It Works

### 双名私仓：宿主推送 28252、job 拉取 mirror:5000

registry 的存储按**路径**索引（semi/eda-base），与访问它的 host 前缀无关。

所以"宿主推 127.0.0.1:28252/library/alpine、job 拉 mirror:5000/library/alpine"指向同一份数据。宿主与内网各用各的可达名字，这是容器网络下私仓的标准接法。

### OrbStack 对 --internal 网络的三个行为差异（实测）

① `--internal` 网络上的容器**不做端口转发**——mirror-registry 若只挂 internal 网络，宿主的 28252 端口发布静默失效（NetworkSettings.Ports 为空）；解法是 registry 双挂网络（compose 侧发端口、airgap 侧给别名）。

② `--internal` **不阻断出网**——job 容器仍可访问外网（真 Docker 会阻断路由），本实验的"外网不可达"探测在 OrbStack 上只能作信息项，真气隙要在物理/防火墙层做。

③ internal 网络内的 DNS 别名正常工作（gitlab/mirror 互达）。

### 气隙 job 的 LFS 陷阱

GitLab 向 job 广播的 LFS 端点跟随 external_url（http://localhost:28200）——气隙容器内不可达。

探针 yml 全局 `GIT_LFS_SKIP_SMUDGE: "1"`（P8 同款），需要大文件的气隙 job 要把 LFS 对象也 mirror 进内网（生产做法：LFS 对象走内网镜像或预置）。

## Pitfalls & Q&A

**坑 1：internal 网络容器无端口转发。** mirror-registry 必须双挂（compose 发端口 + airgap 别名），只挂 internal 时宿主推不进去且无报错（NetworkSettings.Ports 为空是唯一线索）。

**坑 2：runner/job 的镜像名要按"拉取方视角"写。** 同一份数据，宿主叫 127.0.0.1:28252/semi/eda-base，job 叫 mirror:5000/semi/eda-base。

推送与拉取各按其网络内的可达名书写，注册表存储按路径合并。

**坑 3：探针分支 push 被静默吞掉。** 非快进 reject 被 `>/dev/null 2>&1 || true` 吞掉后，verify 查到的是旧流水线——一切"看起来在跑"其实跑的是历史提交。

修法：演示分支用 `checkout -qB <branch> origin/main`（强制重置到 main）+ `push -qf`。

**Q：断网 runner 怎么拿到 job 的 git 仓库？** runner 与 gitlab 同在 airgap-net（别名互达），clone_url=http://gitlab/；LFS 大文件跳过（探针不需要）。

真实气隙要求 LFS 也内网化——生产上 GitLab 的 external_url 应配内网域名，广播的端点自然可达。
