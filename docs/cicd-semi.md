# 🏭 半导体 DevOps · 从零搭建 CI/CD 25 小项目学习清单 · Todo List（自建 GitLab + 开源 EDA，本机全跑通）

> 通过 25 个小项目（每项目 100-300 行配置/脚本）模拟「新人入职半导体设计部门第一天」：把自建 GitLab 平台 → Runner 农场 → RTL lint/仿真流水线 → 种子回归 + License 门禁 → FPGA 构建签名发布 → 气隙/备份/度量，从零做到生产上线
> 约束：本机 macOS（Apple Silicon）+ OrbStack 全跑通、**零云依赖**、全部免费；国内网络——Docker 镜像走 `docker.1ms.run`，pip 走清华源
> 串联机制：完整系统型——全部项目共同生长为**「半导体设计部门内网平台」**（自建 GitLab + rtl-gcd IP 仓库 + Runner 农场 + license-mock + 制品库），每项目标注「产出模块」；⛓️ 集成点 4/11/20 接线，项目 25 🏁 终极串联
> 定位：**devops.md / cicd.md 的半导体特化互补线**——自托管 GitLab、Git-LFS 大文件、开源 EDA 工具链、回归农场、License 门禁、气隙供给均为全新内容，不与已有清单重复（关系见文末）
> 预计周期：11-12 周（每天 1-1.5 小时）

## 🏗️ 终极蓝图（项目 25 完成时的「半导体设计部门内网平台」）

```
 设计/验证工程师 git push ──▶ 自建 GitLab CE (http://localhost:28200)
             │ Group: semi · Protected branch · Server hook 大文件拦截
             │ Git-LFS 托管 PDK/GDS/波形大文件 · MR 审批流
             ▼
     Runner 农场（docker executor + kind K8s executor）
       │ 标签资源池：eda / verilator / yosys / fpga / k8s
       │ 标准执行镜像 eda-base（自建，推 GitLab Registry 28250）
       ▼
  lint 门禁 ─▶ cocotb 单元仿真 ─▶ 种子回归矩阵（16 seeds 并行）
       │                              │
       │                 license-mock 令牌门禁 (28261，并发≤3)
       │                 Slurm 队列对接（项目 15，攻坚选做）
       ▼                              ▼
  JUnit 报告上 MR            夜间回归 + 失败隔离重跑 + 回归仪表盘(Pages 28210)
                                      │
                    yosys 综合 + nextpnr-ice40 布线 → bitstream（fmax 门禁）
                                      ▼
            sha256 + cosign 签名 ─▶ Generic Packages 制品库 ─▶ Release
                                      ▼
                「客户交付包」（tar + 签名 + MANIFEST + 交付审计单）
                                      ▼
        气隙镜像 mirror (28252) · 备份容灾演练 · 流水线度量（DORA 周报）
```

一句话串联：MR 从 push 到 Release 的每一道门，都是某个项目砌的墙。

## 🤖 AI 辅助提示词速查

| 场景 | 提示词 |
|:---|:---|
| **开始一个新项目** | `我要开始半导体 DevOps 项目「[名称]」，平台是本机自建 GitLab CE（http://localhost:28200，OrbStack arm64），被测对象是 rtl-gcd IP 仓库。请给我完整配置/脚本约 [行数] 行（.gitlab-ci.yml/Python/Bash/Dockerfile），macOS + Docker 本机可跑、零云，含可执行验收断言。只输出代码。` |
| **流水线排障** | `我的 GitLab CI 流水线在 [阶段] 失败：[job 日志粘贴]。请分析是 GitLab 配置、runner executor 还是脚本本身问题，给修复后的完整文件。` |
| **EDA 工具链问题** | `我用 [verilator/yosys/nextpnr-ice40/cocotb] 处理 RTL 时出现 [报错粘贴]。请解释工具语义层面的原因并给修复，RTL 与命令都要看。` |
| **写验收脚本** | `请为「[项目名]」写验收脚本：对产出逐条断言（参考清单验收标准），失败输出实际差异，全过打印 [ok]。` |

## 📊 总进度

进度：█████████████████████████░ 25/25 (100%)

| 阶段 | 项目数 | 已完成 |
|:---|:---:|:---:|
| 第一阶段：入职第 1 周——把「半导体内网」立起来 | 4 | 4 |
| 第二阶段：Runner 农场与执行环境 | 3 | 3 |
| 第三阶段：第一条芯片流水线 | 4 | 4 |
| 第四阶段：回归农场——半导体的「重计算」特色 | 5 | 5 |
| 第五阶段：构建、制品与发布 | 4 | 4 |
| 第六阶段：生产化——安全、韧性、度量、上线 | 5 | 5 |
| **合计** | **25** | **25** |

---

## 🗂️ 第一阶段：入职第 1 周——把「半导体内网」立起来（项目 1-4）

> **目标**：一台 Mac 变成半导体公司的内网代码平台——自托管 GitLab 上线、组织权限与 IP 保护落地、超大二进制进 LFS

### [x] 项目 1：GitLab CE 单机上线——半导体内网的第一块地基

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | Omnibus 容器化、内存调优（puma/sidekiq 减配）、健康端点、root 初始化、gitlab-ctl 运维命令 |
| **产出模块** | `semi/01_gitlab_up/`（gitlab_up.sh + configs/docker-compose.yml + configs/gitlab.rb + scripts/healthcheck.sh） |
| **技术栈** | gitlab/gitlab-ce ✅（arm64 容器实跑通过）、OrbStack ✅ |
| **验收标准** | ① `curl -sf http://localhost:28200/users/sign_in` 返回 200、`/api/v4/version` 返回 401（新版 CE 健康端点默认 404，已实测改用真实信号）且 `docker exec gitlab gitlab-ctl status` 全部服务 `run`；② 内存减配生效：`grep puma gitlab.rb` 显示 `worker_processes = 2`，容器 RSS < 6GB（4.5GB 限额下实测稳态 ~3GiB） |
| **⚠️ 风险** | 首次启动实测 4-6 分钟（探活脚本已轮询化）；镜像大层 1.5GB 国内源易断流——已脚本化：`semi/01_gitlab_up/scripts/fallback_pull.sh`（daocloud→R2 签名 URL 小片续传 + OCI load，约 40min，幂等可续传） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「GitLab CE 单机上线」。请给我完整配置约 150 行：docker-compose 起 gitlab-ce（arm64，端口 28200/HTTP、28222/SSH，镜像走国内加速源），gitlab.rb 做内存减配（puma worker 2、sidekiq concurrency 5、关 prometheus），外加 healthcheck.sh 轮询登录页直到 200。附验收命令。只输出代码。`

**完成日期**：2026-10-29
**踩坑记录**：镜像大层 1.5GB 四连败（1ms 断流损坏 / rat.dev 同后端 / xuanyuan 繁忙 / 1panel 403，且 Docker 拉层无断点续传）→ daocloud token + R2 签名 URL + 15MB 小片续传 + OCI load 解决（约 40min）；新版 CE `/-/readiness`、`/-/health` 默认 404 → 就绪信号改 sign_in 200 + api 401；macOS 自带 bash 3.2 不支持 `${var:0:-3}` 负向子串；详见 `semi/01_gitlab_up/README.md` Pitfalls

---

### [x] 项目 2：设计部门工作区——Group 层级与 IP 保护策略

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | Group/子组模型、成员角色矩阵、Protected branches/tags、Server hooks（gitaly 自定义钩子，替代 Premium push rules） |
| **产出模块** | `semi/02_org_guard/`（org_guard.sh + configs/org.yaml + configs/pre-receive + scripts/bootstrap_org.py + scripts/root_token.rb） |
| **技术栈** | GitLab API v4（python-gitlab） |
| **前置** | 项目 1 |
| **验收标准** | ① 受限用户向 `main` 直 push 被拒（`git push` exit≠0 且提示 protected branch）；② `dd` 造 100MB bin 直推被 server hook 拒绝且提示「大文件请走 LFS」，普通小文件提交正常（三条均为真实 git push 实测） |
| **⚠️ 风险** | ⚠️ 已探明：GitLab 19 全局 hook 必须装 `custom_hooks/pre-receive.d/` 子目录（裸 pre-receive 文件不被扫描）且属主 git:git；python-gitlab 8.6 实测可用 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「设计部门工作区」。请给我完整脚本约 200 行：用 python-gitlab 读 org.yaml 幂等建 semi group（子组 ip/design）、成员角色矩阵（Developer/Maintainer）、protected branch main（push=0 只许 MR），并安装 Gitaly 全局 server hook：拒绝 >50MB 非本机直提交、放行 LFS 指针。附验收命令（真实 git push 三连）。只输出代码。`

**完成日期**：2026-10-29
**踩坑记录**：GitLab 19 全局 hook 裸文件 `custom_hooks/pre-receive` **完全不被扫描**，必须放 `custom_hooks/pre-receive.d/` 子目录且 chown git:git（per-repo 旧式 `custom_hooks/` 反而仍兼容，行为相反）；调试 hook 用 root 身份会撞 "dubious ownership" 假信号（`docker exec -u git` 才是真执行环境）；GitLab 19 拒常见词组合密码（semiDev2026lab → 随机 16 位）；验收③若从②失败分支切出会带入 big.bin 被 hook 拒（测试 bug 不是 hook bug）；bash 3.2 全角字符并进变量名（$rc：→ ${rc}:）

---

### [x] 项目 3：设计项目载体——rtl-gcd 仓库与 Git-LFS 大文件治理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | git-lfs migrate、.gitattributes、LFS 对象存储配置、SKIP_SMUDGE 秒级 clone、仓库瘦身对比 |
| **产出模块** | `semi/03_rtl_lfs/`（rtl_lfs.sh + scaffold/{rtl/gcd.v, tb/tb_gcd.py, sim/run_tests.py, docs} + scripts/{bootstrap_rtl.py, gen_bigfiles.sh}） |
| **技术栈** | git-lfs ✅（已装，容器实跑通过）、cocotb 2.1.0 ✅ + iverilog 13.0 ✅（冒烟仿真实跑 6/6 向量过） |
| **前置** | 项目 2 |
| **验收标准** | ① `git lfs ls-files` 列出全部 PDK/GDS/波形假大文件且均为 LFS 实体（第二列 `*`）；② `GIT_LFS_SKIP_SMUDGE=1 git clone` 后 `.git/lfs` 为 0 对象、`git lfs pull` 补全实体（耗时比仅参考——localhost 近内存速度下实测 1.9-3.8x 且噪声大，不作为硬断言）；③ 100MB 文件走 LFS push 成功（server hook 放行指针） |
| **⚠️ 风险** | 假大文件总量 2GB（640/960/480）：原定 260MB 在 localhost 拉不开 skip-clone 差距；载体是后续 20 个项目的 SUT：RTL 足够简单（gcd）但结构完整（rtl/tb/sim/docs），冒烟仿真已在 up 内置 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「rtl-gcd 仓库与 Git-LFS」。请给我完整内容约 200 行：gcd.v（握手协议 RTL）+ cocotb testbench + 合成假大文件脚本（fake_pdk.lib 640MB / fake.gds 960MB / wave.vcd 480MB——localhost 传输太快，小负载拉不开 skip-clone 差距），git lfs migrate import --everything --include=... 迁移历史，.gitattributes 规则，外加 SKIP_SMUDGE 对比测速脚本。附验收命令。只输出代码。`

**完成日期**：2026-10-30
**踩坑记录**：cocotb 2.x runner 拆到 `cocotb_tools.runner`（`cocotb.runner` 不存在）；tb 在 tb/ 目录要插本进程 sys.path（runner 用当前进程 sys.path 重写子进程 PYTHONPATH，extra_env 不生效）；cocotb 2.1.0 `runner.test()` 在 import 失败时仍返回 0——只能解析 results.xml；gcd.v 漏 `` `timescale `` 则 Icarus 精度 1s 跑不了 cocotb 时钟；migrate 模式走 `--include`（位置参数是 ref，`--` 后接模式报错）；migrate 自称 Checkout done 但工作区仍是指针，需显式 `git lfs checkout`；ls-files 的 */- 标记在第二列；localhost 近内存速度使耗时比噪声大（0.55-1.58s 基线漂移），改用 .git/lfs 零下载作硬断言；详见 `semi/03_rtl_lfs/README.md`

---

### [x] ⛓️ 项目 4：集成点①——平台验收，第一个 MR 走通评审流

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | MR 审批流（CE 基础 approvals）、webhook 事件观测、平台级一键自检 |
| **产出模块** | `semi/04_mr_gate/`（mr_gate.sh + scripts/{server.py, dev1_token.rb, mr_flow.py, acceptance.py}） |
| **技术栈** | GitLab API v4、webhook |
| **前置** | 项目 1-3 |
| **验收标准** | ① 分支 → MR → approve → merge 全 API 自动走通，merge 后 main HEAD 变更断言成立；② `acceptance.py` 一键检查（group 结构/保护分支/LFS 对象数/hook 存在/webhook 收到 push 事件）全过打印 `[ok]` |
| **⚠️ 风险** | webhook 接收器只是个会记录事件的 Flask 容器，别做成完整系统——它为后续项目的「事件可观测」打样 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「平台验收集成点」。请给我完整代码约 120 行：stdlib HTTP webhook 监听容器（记录 push/MR 事件到 volume JSON，容器挂进 GitLab 的 compose 网络）+ mr_flow.py（dev1 PAT 开 MR、root 审批合并、断言 main HEAD 变更）+ acceptance.py 九条断言（组树/成员/双项目/保护分支/Gitaly hook/LFS/webhook 注册/事件可达/MR 证据）。附验收命令。只输出代码。`

**完成日期**：2026-10-30
**踩坑记录**：GitLab 默认拒存发往内网地址的 webhook（422）→ 管理员 API 放行 `allow_local_requests_from_web_hooks_and_services`；python-gitlab 8.6 `mr.approve()` 用响应整体替换 attrs 致 iid=None，后续 merge 打到 /merge_requests/None/merge 报 404（approve 后必须重新 get）；merge 405 = detailed_merge_status 非 mergeable（重跑 flow 的同名文件 add/add 冲突，文件名带时间戳解决）；protectedbranches.list() 是简化对象（级别在复数 push_access_levels 列表里）；详见 `semi/04_mr_gate/README.md`

---

## 🗂️ 第二阶段：Runner 农场与执行环境（项目 5-7）

> **目标**：把「一台 runner」扩成「按标签调度的计算农场」，并用不可变的标准镜像固化 EDA 工具链——半导体 CI 的执行力底座

### [x] 项目 5：Runner 注册与标签资源池

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | docker executor、注册令牌体系、标签=资源池语义、concurrent/limit 并发治理、clone_url 内网化 |
| **产出模块** | `semi/05_runner_farm/`（runner_farm.sh + configs/config.toml.template + scripts/{bootstrap_runners.py, make_pipeline.py}） |
| **技术栈** | gitlab/gitlab-runner ✅（arm64 manifest 实测） |
| **前置** | 项目 4 |
| **验收标准** | ① 测试流水线 job 按 `tags: [eda]` 精确落到指定 runner（job 日志可查 runner 名与 IP）；② `concurrent = 2` 时同时触发 3 个 sleep job，时间戳证明第 3 个等前面完成才开始（排队间隔 > job 时长） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「Runner 注册与标签资源池」。请给我完整配置约 150 行：管理员 API POST /user/runners 签发 glrt 令牌 + 声明式 config.toml 模板注册两个 docker executor 池（eda concurrent=2 / fpga concurrent=1，network_mode 进 GitLab compose 网络，clone_url 用内网名），runner-lab 靶场流水线（3 个 sleep 6 的 eda job + fpga 探针），外加空闲等待 + 起跑时序排序的排队观测脚本。附验收命令。只输出代码。`

**完成日期**：2026-10-30
**踩坑记录**：GitLab 16+ 已废除 registration token——新流程 POST /user/runners 拿 glrt 令牌（python-gitlab 的 runners.create 走老端点要 token，必须裸 http_post）；GET /runners 对 admin 也有可见性过滤返回空，清理旧 runner 必须 GET /runners/all（gl.runners.all 是方法不是 manager → http_get）；job 容器网络靠 runners.docker.network_mode 进 compose 网络，clone_url 内网名才生效；排队测量必须先等 runner 空闲（跨流水线交错实测 -14.4s 失真），空闲判定只认 JSON 数组（404 dict len=1 冒充 busy）；OrbStack 重启后偶发空响应，GET/POST 全加重试；mid-experiment OrbStack 曾因卡死 pull 整机僵死，应用级重启（osascript quit + open）可救；详见 `semi/05_runner_farm/README.md`

---

### [x] 项目 6：EDA 标准执行镜像——工具链不可变交付

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | EDA 工具链 Dockerfile（apt 版 verilator/yosys/iverilog + pip cocotb）、GitLab Container Registry、镜像版本即环境契约 |
| **产出模块** | `semi/06_eda_image/`（eda_image.sh + configs/{Dockerfile, smoke-test.sh}） |
| **技术栈** | Docker buildx（arm64，--provenance=false）、GitLab Registry（28250 已启用）、CI_JOB_TOKEN allowlist |
| **前置** | 项目 5 |
| **验收标准** | ① CI job 用 `image: registry:28250/semi/eda-base:1.0` 跑 smoke-test，四个版本号全打印（verilator/yosys/iverilog/cocotb import）；② 镜像被固定 tag 引用时，删本地镜像再跑 job 仍能从 Registry 拉起（`docker images` 无本地构建版） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「EDA 标准执行镜像」。请给我完整内容约 150 行：ubuntu:24.04 基底 Dockerfile（apt 装 verilator/yosys/iverilog + python3-dev/build-essential——cocotb 在 linux-aarch64 无 wheel 需源码编译、pip cocotb 固定版本、全程清华源），smoke-test.sh 打印四工具版本，启用平台 Registry(28250)+推送（buildx --provenance=false），CI job 跨项目引用（CI_JOB_TOKEN allowlist）。附验收命令。只输出代码。`

**完成日期**：2026-10-30
**踩坑记录**：cocotb 在 linux-aarch64/cp312 无预编译 wheel → 源码编译需 build-essential+python3-dev；buildx 默认 provenance attestation 让 GitLab Registry 报 blob unknown → --provenance=false；跨项目拉私有镜像要 CI_JOB_TOKEN allowlist（POST /projects/:id/job_token_scope/allowlist，降级 public）；ProjectFile.decode() 返回 bytes 要再 .decode()；compose 加端口后必须重建容器（幂等分支别忘了）；验收②的流水线基线要在开头重取（① 自己也触发流水线）；详见 `semi/06_eda_image/README.md`

---

### [x] 项目 7：kind 弹性农场——K8s executor 与队列模拟

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | GitLab Runner K8s executor、每 job 一 pod、requests/limits 资源约束、节点污点模拟计算队列 |
| **产出模块** | `semi/07_kind_farm/`（kind_farm.sh + configs/{runner-k8s.toml, runner-deploy.yaml}） |
| **技术栈** | kind 0.32.0 ✅（semi-farm 集群实跑）、kubectl 1.33 ✅、GitLab Runner K8s executor（探活通过，未用降级方案） |
| **前置** | 项目 6 |
| **验收标准** | ① tag=`k8s` 的 job 在 kind pod 内执行（日志含 pod 名，`kubectl get pods` 可见创建/销毁）；② 给 runner 设 2 并发 + 低资源 limits 后连发 4 job，观测脚本记录到 ≥2 次 pod 处于 Pending（排队证据） |
| **⚠️ 风险** | 已探活通过；注意 OrbStack VM 实际内存默认 16G（多集群同住会 OOM 僵死整机），本系列容器一键启停用 `semi/ctl.sh` |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「kind 弹性农场」。请给我完整配置约 200 行：kind 集群（daocloud 节点镜像）+ K8s executor runner 的声明式部署清单（ConfigMap 挂 config.toml + RBAC Role/RoleBinding + Deployment 挂 /etc/gitlab-runner，tags=k8s、concurrent=2、cpu/mem 低限额、helper_image 走 daocloud）+ clone_url 用 Mac 局域网 IP + Pending 观测脚本。附验收命令。只输出代码。`

**完成日期**：2026-10-30
**踩坑记录**：K8s executor 链路的四层坑——RBAC 缺失报 secrets is forbidden；ConfigMap 挂载路径必须 /etc/gitlab-runner（挂 home 报 config not found）；helper 镜像默认 registry.gitlab.com 被墙（helper_image 指 daocloud，tag 带架构前缀 arm64-v19.5.2 且与 runner 版本一致）；kind load 对多架构镜像报 digest 缺损（docker save | ctr import 绕行）。job Pod 名是 runner-<hash>-project-N-concurrent-X 而非 runner-k8s-*（断言模式别写错）；Pod 回连宿主用 Mac 局域网 IP（compose 别名在 Pod 网络不生效）；ConfigMap 渲染的占位符行缩进要归零否则 YAML 崩。环境事故：OrbStack VM 实际 16G，多集群同住 OOM 僵死整机（两次），orbctl config set memory_mib 调节 + semi/ctl.sh 一键启停本系列 5 容器；详见 `semi/07_kind_farm/README.md`

---

## 🗂️ 第三阶段：第一条芯片流水线（项目 8-11）

> **目标**：RTL 从 push 到「红绿分明」——lint 门禁、cocotb 单元仿真、编译仿真加速，全部以 MR 为触发核心

### [x] 项目 8：Lint 门禁——verilator 把住第一道关

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | verilator --lint-only -Wall、告警升级为错误、GitLab codequality report 格式、MR widget 集成 |
| **产出模块** | `semi/08_lint_gate/`（lint_gate.sh + configs/gitlab-ci.yml + tools/verilator2codequality.py；CI 文件随 up 推进 rtl-gcd 仓库） |
| **技术栈** | verilator ✅（brew 5.052 bottle）/ 镜像内 apt 版 ✅ |
| **前置** | 项目 6 |
| **验收标准** | ① 注入未驱动信号 bug → MR 流水线 lint 红 + codequality.json 可从 API 拉取（实测 3 条告警）；② 修复（删演示模块）后全绿（实测 pipeline success）——均以真实 git push + MR 验证 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「Lint 门禁」。请给我完整内容约 150 行：lint job（verilator --lint-only -Wall，跑 eda-base:1.0，rules 含 merge_request_event，全局 GIT_LFS_SKIP_SMUDGE=1——Pod 内拉 LFS 走 GitLab 广播的 localhost 端点不可达）+ verilator2codequality.py（fingerprint=sha256(path:line:msg)）+ 门禁按 JSON 条数判（[] 是非空文件）+ codequality 双写（reports 给 widget，paths 进归档供 API 拉取）+ 按 commit sha 等流水线（auto-cancel 竞态）。附验收命令。只输出代码。`

**完成日期**：2026-10-31
**踩坑记录**：Pod 内 LFS 端点是 GitLab 广播的 localhost → 全局 GIT_LFS_SKIP_SMUDGE=1；干净 lint 的 codequality.json 是 []（3 字节），[ -s ] 门禁误伤 → 按 JSON 条数判；report 类 artifact 不进 /artifacts zip（单文件路由实测 404）→ paths 双写；MR 流水线 auto-cancel 竞态 → 按 commit sha 等待；bash 3.2 local 同行多赋值不保证从左到右（$iid unbound）→ 拆行；git-lfs 往 stdout 喷 Deleted 污染 $() 捕获 → 取最后一行；-Wall 下 UNUSED/DECLFILENAME 靠删块清；详见 `semi/08_lint_gate/README.md`

---

### [x] 项目 9：单元仿真——cocotb 首条测试流水线

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | cocotb runner API、iverilog 后端、JUnit 报告接入 MR 测试 Tab、仿真超时治理 |
| **产出模块** | `semi/09_unit_sim/`（unit_sim.sh + configs/gitlab-ci.yml；CI 随 up 推进 rtl-gcd） |
| **技术栈** | cocotb 2.1.0 ✅、iverilog（brew/apt ✅） |
| **前置** | 项目 8 |
| **验收标准** | ① 注错（翻转 tb 期望值）→ unit 红 + JUnit tests=1 failures=1 且 failure 精确指向 smoke_gcd（实测）；② 修复 → 全绿 + JUnit tests=1 failures=0 可从归档拉取（实测） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「cocotb 单元仿真流水线」。请给我完整内容约 180 行：unit job（跑 sim/run_tests.py=cocotb 2.x runner+iverilog，junit report sim/results.xml 并 paths 双写——report 类不进 /artifacts zip，跑在 eda-base:1.0）+ 注错验证（翻转 tb 期望值，failure 应精确指向用例名）。附验收命令。只输出代码。`

**完成日期**：2026-10-31
**踩坑记录**：junit report 同样不进 /artifacts zip → paths 双写 sim/results.xml（P8 的 report 盲区规律复用）；注错设计选"翻 tb 期望值"而非改 RTL（tb 是验证程序，模拟验证错最常见）；修复用 git checkout main -- 还原最干净；详见 `semi/09_unit_sim/README.md`

---

### [x] 项目 10：编译仿真与缓存——回归提速的工程学

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | verilator --cc 编译模型、cache:key 按 RTL 哈希、stage 间 artifacts 传递、大波形 artifact 瘦身 |
| **产出模块** | `semi/10_sim_cache/`（sim_cache.sh + configs/{gitlab-ci.yml, tb_main.cpp}；sim/tb_main.cpp 随 up 推进 rtl-gcd） |
| **技术栈** | verilator ✅、GitLab cache/artifacts |
| **前置** | 项目 9 |
| **验收标准** | ① bust 提交（run1 cache_hit=false compile=4s）→ run2（cache_hit=true compile=0s）降幅 ≥70%（实测）；② artifacts 归档 0KB < 10MB，20MB 假波形被 exclude 排除（实测） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「编译仿真与缓存」。请给我完整内容约 180 行：sim job（verilator --cc --exe --build 产 C++ 模型 + tb_main.cpp 驱动同组向量，cache key.files=[rtl/gcd.v, sim/tb_main.cpp] paths=[sim/obj_dir]，hit 判定在编译前，sim_meta.json 记 cache_hit/compile_seconds，artifacts exclude 波形）+ bust-run1-run2 对比脚本（bust 流水线即 MISS run）。附验收命令。只输出代码。`

**完成日期**：2026-10-31
**踩坑记录**：hit 判定必须在编译前（编译后 Vgcd 恒存在恒 true）；bust push 自己触发的流水线就是 MISS run（原设计把它当准备步骤导致 MISS 被消耗、对比跑成 HIT/HIT）；演示分支不匹配 rules 得到 0 jobs 的 failed 流水线 → 对比在 main 上做空提交；workhorse 偶发 "404 page not found" 纯文本（api 重试要按内容过滤）；wait_pipeline_done 参数传错（状态当 id）轮询 /pipelines/created 超时假象；OrbStack 16G 下 kind+GitLab 同住三次 OOM 僵死 → kind 节点平时 stop（semi/ctl.sh 管理）；详见 `semi/10_sim_cache/README.md`

---

### [x] ⛓️ 项目 11：集成点②——MR 全流水线与注错验证

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | needs DAG 串 lint→unit→sim、门禁失效注入测试、pipeline badge |
| **产出模块** | `semi/11_dag_gate/`（dag_gate.sh + configs/gitlab-ci.yml 终装；badge 进 rtl-gcd README） |
| **技术栈** | GitLab CI needs/rules/badge |
| **前置** | 项目 8-10 |
| **验收标准** | ① 注入 lint 级 bug → lint 红 且 unit/sim 因 needs 依赖未执行（API 断言两 job 状态为 canceled/created）；② 注入仿真级 bug → lint 绿 unit 红；③ 修复后全绿，README badge 渲染 pipeline 状态 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「MR 全流水线集成点」。请给我完整内容约 150 行：终装 .gitlab-ci.yml（needs DAG：lint→unit→sim，rules 含 MR/main，badge 进 README）+ 注错器（lint 级=加未驱动模块 / 仿真级=翻 tb_main.cpp 期望值——注意仿真级不影响 cocotb 的 unit）+ 下游断言按 skipped 认。附验收命令。只输出代码。`

**完成日期**：2026-10-31
**踩坑记录**：needs 拦截的下游状态是 skipped（非 canceled）；仿真级注错（tb_main.cpp）不影响 cocotb 的 unit——双验证程序故障域隔离是特性；badge 对 HTTP 实例 302 → curl -L；badge URL 里的项目路径需 URL 编码由 GitLab 处理；详见 `semi/11_dag_gate/README.md`

---

## 🗂️ 第四阶段：回归农场——半导体的「重计算」特色（项目 12-16）

> **目标**：把单次仿真扩成规模化回归——种子矩阵、夜间调度、License 并发门禁、农场队列、质量仪表盘，这是半导体 CI 与互联网 CI 分道扬镳的地方

### [x] 项目 12：种子回归矩阵——16 路并行的重计算

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | parallel:matrix、cocotb random seed 注入、子 job 结果聚合、timeout/retry 策略 |
| **产出模块** | `semi/12_seed_matrix/`（seed_matrix.sh + configs/{gitlab-ci.yml, tb_random.py, run_regression.py, aggregate_results.py}） |
| **技术栈** | GitLab parallel:matrix、Python |
| **前置** | 项目 11 |
| **验收标准** | ① 流水线页可见 16 个矩阵子 job，聚合 job 输出 `pass=16 fail=0`（JSON 汇总全部 seed）；② 植入「seed=7 必败」bug → 聚合正确报告 15/16 且失败清单精确含 seed 7 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「种子回归矩阵」。请给我完整内容约 200 行：regression job（parallel:matrix SEED=1..16，tb_random.py 每种子 32 组随机向量对拍 math.gcd，summary_seed_N.json 按种子命名防 needs 下载覆盖）+ aggregate job（needs 全部子 job，glob 收集校验 collected==16）+ seed7 注错只发生在演示分支。附验收命令。只输出代码。`

**完成日期**：2026-10-31
**踩坑记录**：注入代码写进干净模板 → 基线永远 15/16（模板必须干净，注入只在演示分支）；needs 上游失败 → 聚合 job 被 skip（GitLab 语义）→ 失败时的聚合证据用同一聚合器对子 artifact 离线跑；summary 按种子命名防 needs 下载覆盖；16 路矩阵打满农场时 API 会抖（耐心+重试）；详见 `semi/12_seed_matrix/README.md`

---

### [x] 项目 13：夜间回归与失败治理——flaky 的隔离与识别

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~220 行 |
| **核心知识点** | scheduled pipeline、失败种子隔离重跑（child pipeline）、artifact 保留期策略、flaky 历史识别 |
| **产出模块** | `semi/13_nightly/`（nightly.sh + configs/{gitlab-ci.yml, flaky_hunter.py, nightly-rerun.yml}） |
| **技术栈** | GitLab schedules、child pipeline、API |
| **前置** | 项目 12 |
| **验收标准** | ① nightly schedule 建立且 API 可查其 crontab；② 植入「seed=7 且 30% 概率失败」的确定性 flaky（seed 派生伪随机）→ flaky_hunter.py 拉最近 10 次结果把 seed 7 标记为 flaky（时红时绿），child pipeline 只重跑 seed 7 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「夜间回归与失败治理」。请给我完整内容约 220 行：nightly schedule（API 建 cron 0 2 * * *）+ flaky_hunter.py（扫全 refs 最近 N 条含回归矩阵的流水线，按种子统计红绿分 healthy/flaky/broken——窗口要覆盖至少一次失败）+ regression_rerun job（FAILED_SEEDS 变量 + job 内 case 守卫只执行失败种子，触发用 POST /pipeline 的 JSON body）。附验收命令。只输出代码。`

**完成日期**：2026-10-31
**踩坑记录**：flaky 判定是历史统计——ref 只扫 main 会漏 MR 上的真实失败、窗口 N=5 太小要覆盖至少一次失败（本例 N=25）；POST /pipeline 的表单 variables 在 GitLab 19 报 variables is invalid → JSON body；flaky_hunter.py 忘 import json；needs 语义问答见 `semi/12_seed_matrix/README.md` 坑 2；详见 `semi/13_nightly/README.md`

---

### [x] 项目 14：License 门禁——EDA 许可证的并发管控

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心知识点** | FlexLM 并发许可模式、license-mock 令牌服务（租约+TTL 回收）、CI job 检出/归还封装、排队上限验证 |
| **产出模块** | `semi/14_license_gate/`（license_gate.sh + configs/{license_server.py, with_license.sh, lic.py, gitlab-ci.yml}） |
| **技术栈** | FastAPI、Docker（28261）、GitLab CI variables |
| **前置** | 项目 12 |
| **验收标准** | ① 4 路并发 holder 容器抢 3 令牌：available=0 + 第 4 路日志含 lease wait + 4 路全走完检出/归还生命周期（实测）；② kill -9 持租容器（无 release）→ TTL 120s 到期自动回收 available 回 3（实测） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「License 门禁」。请给我完整代码约 250 行：license-mock（stdlib HTTP，/acquire 池空 429 /release /status，池 3，TTL sweeper 线程兜底回收——注意 slim 容器无 curl，客户端用 urllib）+ with_license.sh（trap EXIT 归还 + 60s 排队）+ 4 路并发与 kill -9 两组破坏性验收（holder 容器 + 时序敏感断言要等齐）。附验收命令。只输出代码。`

**完成日期**：2026-10-31
**踩坑记录**：python:3.12-slim 无 curl → 客户端换 urllib（lic.py）；占用判定必须在事前（容器启动 4s 后查 available 会读到未 acquire 的）；macOS bind mount 不保留 +x → 脚本用 bash 调用；kill -9 的归还靠服务端 TTL sweeper（trap EXIT 兜不住 kill -9）；TTL 设 120s 加速验收（清单写 5min）；详见 `semi/14_license_gate/README.md`

---

### [x] 项目 15：Slurm 队列对接（攻坚·选做）——真实农场的调度器

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心知识点** | Slurm 架构（controller/compute/munge）、sbatch/squeue/sacct、GitLab job 与 HPC 队列的桥接模式 |
| **产出模块** | `semi/15_queue_farm/`（queue_farm.sh + configs/{slurm_mock.py, queue_client.py}） |
| **技术栈** | Slurm（⚠️ 开工探活：arm64 现成镜像稀缺，首选自建 Ubuntu+slurm-wlm 镜像） |
| **前置** | 项目 12、14 |
| **验收标准** | ① sbatch 提交 → sacct 轮询 PENDING/RUNNING → COMPLETED → 输出取回（实测）；② 4 作业撞并发 2 → squeue 可见 RUNNING=2 + PENDING 排队（实测）；CI 侧 queue_regression job 已接 rtl-gcd |
| **⚠️ 风险** | 已按预案走降级路线：slurm-mock 1:1 复刻 sbatch/squeue/sacct/output 四端点（真 Slurm 环境链=slurm-wlm 构建+Munge 在 16G VM 过长）；换真 Slurm 只改 queue_client.py |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「HPC 队列对接」。请给我完整内容约 250 行：slurm-mock（stdlib HTTP：POST /sbatch、GET /squeue /sacct /output，FIFO + MAX_RUNNING=2，作业脚本在容器 bash 执行）+ queue_client.py（提交→轮询终态→取回输出→透传退出码）+ CI queue_regression job（allow_failure: true 旁路语义）。附验收命令。只输出代码。`

**完成日期**：2026-10-31
**踩坑记录**：按清单预案走 slurm-mock 降级路线（真 Slurm 环境链在 16G VM 过长）——四端点语义 1:1，学习目标（提交-轮询-取回）保全；CI 侧 queue_regression 设 allow_failure: true（HPC 旁路作业不 block 主线）；详见 `semi/15_queue_farm/README.md`

---

### [x] 项目 16：回归仪表盘——让质量趋势可见

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | GitLab Pages 自托管配置、回归结果历史留存、纯静态趋势图（SVG）、看板数据管道 |
| **产出模块** | `semi/16_dashboard/`（dashboard.sh + tools/render_dashboard.py + history/ 真实快照） |
| **技术栈** | GitLab Pages（28210）、Python（无前端框架） |
| **前置** | 项目 13 |
| **验收标准** | ① http://localhost:28210/ 返回 200 且含 SVG 折线与历史表（实测）；② 页面 passed 数字与最新快照一致（数据一致性断言，实测 passed=16/16） |
| **⚠️ 风险** | 已按预案走旁挂 nginx 路线（Pages 的 Omnibus 配置链探活成本高）；渲染与部署解耦，换 Pages 只改部署层 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「回归仪表盘」。请给我完整内容约 200 行：history 快照采集（从 GitLab API 拉真实 aggregate artifact——基线/注错/最新三份，缺失自然跳过）+ render_dashboard.py（快照→HTML+内联 SVG 折线，无 JS 框架）+ nginx 容器（28210 只读挂载）。附数据一致性验收命令。只输出代码。`

**完成日期**：2026-10-31
**踩坑记录**：aggregate artifact 受 expire_in 限制（基线 146 的已过期 404）——采集脚本对缺失快照自然跳过；OrbStack 第 4 次僵死（16G 下多容器+编译累积）→ 应用级重启后恢复；详见 `semi/16_dashboard/README.md`

---

## 🗂️ 第五阶段：构建、制品与发布（项目 17-20）

> **目标**：从 RTL 到可交付的「硬件产品」——FPGA 综合流水线、制品签名治理、客户交付包，硬件版 release 工程

### [x] 项目 17：FPGA 综合流水线——yosys + nextpnr 到 bitstream

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | yosys synth_ice40、nextpnr-ice40 布线与 fmax 时序报告、时序门禁、icepack 出 bitstream |
| **产出模块** | `semi/17_fpga/`（fpga.sh + configs/{gitlab-ci.yml, Makefile, gcd.pcf, extract_fmax.py}；随 up 推进 rtl-gcd） |
| **技术栈** | yosys/nextpnr-ice40/icepack ✅（brew native 与 yowasp WASM 双路实测同结果 120.79MHz） |
| **前置** | 项目 11 |
| **验收标准** | ① 50MHz 流水线绿：fmax.json 有效（实测 fmax=120.79）且 bitstream .bin 在归档（zip 完整性校验后断言，实测）；② 200MHz 约束 → 时序失败流水线红（实测；120 在 fmax 裕量内故改 200） |
| **⚠️ 风险** | gcd 模块需配 iCE40 管脚约束 PCF 与顶层 wrapper（syn/ 内一次性给全）；brew nextpnr-ice40 若缺 chipdb 则 `pip install yowasp-nextpnr-ice40` 替代（清华源实测有包） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「FPGA 综合流水线」。请给我完整内容约 200 行：syn/Makefile（工具名变量化 YOSYS/PNMR/ICEPACK——CI 用 yowasp WASM 版，yosys synth_ice40 + nextpnr-ice40 --hx8k --freq 约束 + icepack）+ extract_fmax.py（正则时钟名通配全局缓冲改名 clk$SB_IO_IN…，fmax<约束即红）+ PCF（ct256 管脚名是网格坐标 B1/C14，逐信号探测分配）+ fpga job（pip --target 装 yowasp + cache，gitlab 归档下载要 testzip 校验截断）。附验收命令。只输出代码。`

**完成日期**：2026-11-01
**踩坑记录**：ct256 管脚名是网格坐标（B1/C14），数字名部分"合法"组合后失败 → 逐信号探测分配；fmax 正则要通配时钟名（PCF 输入经全局缓冲改名 clk$SB_IO_IN_$glb_clk）；CI 变量 FREQ_MHZ 会架空 sed（make 命令行参数优先）且空展开穿透 ？= 默认 → 删变量裸 make；yowasp --target 装法要 PATH+PYTHONPATH 双导出；归档边生成边流下载截断（固定 ~6.9KB 断）→ testzip 校验 + curl --max-time 180 + 重试 3 分钟；120 在实测 fmax 120.79 裕量内，注错点改 200；eda-base:1.1 重镜像构建压死 16G VM → 改 job 级 pip+cache；详见 `semi/17_fpga/README.md`

---

### [x] 项目 18：制品治理——bitstream 的版本化与签名

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | Generic Packages API、checksum 校验、cosign sign-blob 签名、制品保留策略、不可变版本纪律 |
| **产出模块** | `semi/18_artifacts/`（artifacts.sh + tools/{publish_artifact.sh, verify_artifact.sh} + configs/signing-config.json） |
| **技术栈** | cosign（brew 需装）、syft ✅（已装 1.51.1）、Generic Packages API |
| **前置** | 项目 17 |
| **验收标准** | ① 发布 v<ts> 三件套（bin+manifest+签名）→ verify 三重校验全过（下载/sha256 一致/cosign 验签，实测）；② 同版本二次发布被不可变守卫拒绝 exit≠0（实测，守卫探测制品文件而非列表过滤） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「制品治理」。请给我完整内容约 200 行：publish_artifact.sh（不可变守卫探测制品文件 URL——packages?version= 列表过滤实测不生效；cosign 3.x 用 --bundle + signing-config 离线配置，--tlog-upload 已废弃）+ verify_artifact.sh（下载/sha256/verify-blob --bundle）+ CI job（PAT 注入 masked+protected）。附验收命令。只输出代码。`

**完成日期**：2026-11-01
**踩坑记录**：cosign 3.x 三连——sign-blob 默认 bundle 格式（--bundle 落盘）、--tlog-upload=false 废弃改 --signing-config（signing-config create 生成离线配置）、yowasp-icestorm 包不存在；packages?version= 列表过滤实测不生效 → 守卫直接探测制品文件 URL；pipefail + grep -q 的 SIGPIPE 误判（发布脚本 141 被判失败）→ 输出落盘再 grep；guard 拒绝后的 verify 404 是级联失败，排障看第一个错；详见 `semi/18_artifacts/README.md`

---

### [x] 项目 19：发布工程——从 vTag 到客户交付包

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~220 行 |
| **核心知识点** | tag 触发流水线、MR 列表自动汇总 changelog、GitLab Release API、客户交付包（tar+签名+审计单） |
| **产出模块** | `semi/19_release/`（release.sh + tools/make_release.py；release stage 随 up 推进 rtl-gcd） |
| **技术栈** | GitLab Releases API、tar/sha256 |
| **前置** | 项目 18 |
| **验收标准** | ① 推 v0.1.0 tag → Release 自动创建且 assets 含交付包链接、changelog 含上一 tag 以来全部 MR 标题（API 断言）；② 交付包解开后 MANIFEST.sha256 逐条校验通过，audit.json 含版本/时间/触发人/流水线链接四字段 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「发布工程」。请给我完整内容约 220 行：release job（$CI_COMMIT_TAG =~ /^v/ 触发，needs fpga——fpga rules 要同步放行 tag 否则 needs 悬空整条 0 jobs failed）+ make_release.py（MR changelog、tar 包内置 MANIFEST.sha256、Release assets；CI 容器内 URL 走 gitlab 别名、/uploads 收 multipart、/packages 收 PUT、无 curl 全 urllib）。附验收命令。只输出代码。`

**完成日期**：2026-11-01
**踩坑记录**：needs 悬空（fpga rules 没放行 tag）→ tag 流水线 0 jobs 直接 failed；protected 变量对 tag 不生效（GITLAB_PAT 读不到）→ 关 protected 或配 v* wildcard；CI 容器内 localhost 不是 GitLab（走 gitlab 别名）且无 curl（uploads 手工 multipart / packages 用 PUT，全 urllib）；交付包要内置 MANIFEST.sha256 供消费端对账；OrbStack 又僵死一次（16G 限制下多容器累积）；详见 `semi/19_release/README.md`

---

### [x] ⛓️ 项目 20：集成点③——commit 到 Release 全链手动演练

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | 全链 DAG 装配、阶段耗时盘点、断点记录方法论 |
| **产出模块** | `semi/20_full_chain/`（full_chain.sh；终版 yml 与演练报告随 up/verify 推进 rtl-gcd 仓库） |
| **技术栈** | GitLab CI needs/rules 全集 |
| **前置** | 项目 12-19 全部 |
| **验收标准** | ① 全绿轮：MR 流水线 lint→unit→回归矩阵→fpga→制品 全链 success，各 job 耗时写入 docs/full_chain_report.md（实测 pipeline #238）；② 注错轮：regression[3] 红 → fpga=skipped（needs 阻断，实测）——DAG 语义即断言 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「全链集成点」。请给我完整内容约 150 行：终版 yml 总装（fpga/publish/release 收拢 build 阶段，fpga needs aggregate——回归红阻断综合；needs 不可前向引用 stage，否则 0 jobs failed）+ 全绿/注错双轮演练脚本（job 状态与耗时自动写入演练报告）。附验收命令。只输出代码。`

**完成日期**：2026-11-01
**踩坑记录**：needs 不可前向引用 stage（release 在 regression 阶段 needs build 阶段的 fpga → 整条流水线 0 jobs failed、yaml_errors=None）→ POST /ci/lint 可 push 前校验；fpga 从 sim 挪进 build 阶段并 needs aggregate——回归红阻断综合（EDA 语义：功能先行）；演练报告自动入仓（job 状态+耗时），配置演进后重跑可对比耗时漂移；详见 `semi/20_full_chain/README.md`

---

## 🗂️ 第六阶段：生产化——安全、韧性、度量、上线（项目 21-25）

> **目标**：把「能跑的流水线」变成「敢上生产的平台」——IP 防泄漏、气隙供给、备份容灾、DORA 度量，最后一键上线验收

### [x] 项目 21：流水线安全加固——半导体 IP 防泄漏

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | masked/protected variables、protected runner 标签、fork MR 的 secret 隔离、artifact 公开性审计 |
| **产出模块** | `semi/21_security/`（security.sh：变量收紧 + 三把锁审计断言） |
| **技术栈** | GitLab CI security model、API |
| **前置** | 项目 20 |
| **验收标准** | ① dev1 的 PAT 读 protected 变量接口被拒 HTTP 403（外部身份不可达，实测）；② 四项目可见性审计全 private + 匿名 LFS batch 请求 401（实测） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「流水线安全加固」。请给我完整内容约 200 行：变量 masked+protected 收紧（幂等审计并纠正）+ 三把锁断言（外部身份读变量 403 / 四项目可见性 private / 匿名 LFS batch 401）+ protected 对 tag 的生效语义（P19 坑）。附验收命令。只输出代码。`

**完成日期**：2026-11-01
**踩坑记录**：protected 变量是 ref 级隔离（fork MR/非 protected ref 天然拿不到，无需逐用户）；security.sh 里 for 循环的 local 多变量与 $pvis（ 多次踩）逐个排掉；审计断言要容错"项目不存在"（unknown 分支）；详见 `semi/21_security/README.md`

---

### [x] 项目 22：气隙供给与镜像 mirror——内网自足演练

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | 私有 registry 镜像缓存（pull-through 思想）、依赖镜像白名单、断网 runner 隔离网段演练 |
| **产出模块** | `semi/22_airgap/`（airgap.sh + configs + data/registry 私仓存储） |
| **技术栈** | registry:2（28252）、Docker network |
| **前置** | 项目 21 |
| **验收标准** | ① 白名单镜像入 28252 私仓且 catalog 三类齐全（实测）；② 断网 runner（internal 网络）airgap 探针 job 全绿 + 镜像来自 mirror:5000 + 内网 gitlab 200（实测） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「气隙供给」。请给我完整内容约 180 行：mirror-registry 双挂网络（compose 发端口 28252 供宿主推、airgap-net 别名 mirror 供 job 拉——OrbStack 对 internal 网络不做端口转发）+ runner-offline（internal 网络 + network_mode=airgap-net + 镜像名 mirror:5000）+ 探针 job（GIT_LFS_SKIP_SMUDGE + 内网 200/镜像来自私仓断言）。附验收命令。只输出代码。`

**完成日期**：2026-11-01
**踩坑记录**：OrbStack 三差异——--internal 网络容器不做端口转发（mirror 双挂 compose+airgap 解决）、--internal 不阻断出网（外网探测降级信息项）、演示分支 push 静默 reject 被 || true 吞掉（checkout -qB + push -qf 修）；镜像名按拉取方视角写（宿主 127.0.0.1:28252 推、job mirror:5000 拉，registry 按路径存储自然合并）；气隙 job 的 LFS 端点广播 localhost 不可达 → GIT_LFS_SKIP_SMUDGE；旧 runner-offline 容器残留会让 up 的 rm 报 conflict；详见 `semi/22_airgap/README.md`

---

### [x] 项目 23：备份与容灾——半夜炸机演习

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | gitlab-backup create/restore、secrets 文件的关键性、LFS/Registry 数据一致性、RTO 计时 |
| **产出模块** | `semi/23_dr/`（dr.sh：backup/restore/verify 全流程；data/ 备份归档） |
| **技术栈** | gitlab-backup、Docker volume |
| **前置** | 项目 22 |
| **验收标准** | ① 备份 7.2G（含 LFS）→ 毁容器毁卷 → 新容器恢复+secrets → API/clone/LFS 三层断言全过（实测）；② RTO 262 秒（< 30min，实测记录在案）；扩展属主错误（gitlab-psql 角色）ALTER OWNER 后恢复成功 |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「备份与容灾」。请给我完整内容约 200 行：dr.sh（backup：gitlab-backup create + secrets 单独拷出；restore：毁卷→alpine 预置 backups 目录 chmod 777→ALTER EXTENSION OWNER TO gitlab→gitlab-backup restore→secrets 回放→reconfigure）+ 三层功能断言（API/clone/LFS）+ RTO 计时。附验收命令。只输出代码。`

**完成日期**：2026-11-01
**踩坑记录**：GitLab 19.5 备份日志不再带引号（tarname 正则按裸格式匹配+旧格式兼容）；备份 tar 拷进卷要 /target/backups/ + chmod 777（restore 以 git 用户读）；扩展属主错误（gitlab-psql 角色，must be owner）会中止 pg_restore → ALTER EXTENSION OWNER TO gitlab 修；gitlab.rb 是 ro bind mount 不能 docker cp 覆盖（config 从仓库来）；secrets 决定 PAT 链路（clone 断言同时验证 secrets）；RTO 262s 实测；详见 `semi/23_dr/README.md`

---

### [x] 项目 24：流水线度量——DORA 四指标与瓶颈定位

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | GitLab API 批量取数、DORA 四指标映射（部署频率/变更前置时间/MTTR/变更失败率）、瓶颈 stage 定位 |
| **产出模块** | `semi/24_metrics/`（metrics.sh + tools/{dora_report.py, test_dora.py} + dora_week.json） |
| **技术栈** | Python、GitLab API |
| **前置** | 项目 20 |
| **验收标准** | ① 已知数据集单测：10 条假流水线（3 红 7 绿）→ 成功率 70%/CFR 30%/MTTR 60min 全过（unittest 实测）；② 真实数据集：瓶颈 stage 与独立 API 聚合一致（同窗 20 条全 ref，实测 lint） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 项目「流水线度量」。请给我完整内容约 200 行：dora_report.py（collect 与纯数学 compute 分离——单测喂假对象锁死数学；list() 懒加载要逐条 get 拿 duration；参数顺序 token文件/project/out）+ 单测（3红7绿数据集）+ 交叉验证（独立聚合对拍瓶颈，同窗 20 条全 ref）。附验收命令。只输出代码。`

**完成日期**：2026-11-01
**踩坑记录**：list() 懒加载对象缺 duration → 逐条 get；compute/collect 分离（单测喂假对象锁数学）；main 参数顺序与调用方对齐（URL 被当 token 文件 open 踩过）；瓶颈交叉验证窗口必须与报告一致（ref=main 10 条 vs 全 ref 20 条实测不一致假失败）；详见 `semi/24_metrics/README.md`

---

### [x] 🏁 项目 25：终极串联——平台一键上线验收

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~300 行 |
| **核心知识点** | 平台即代码（全量 bootstrap）、从零重放、12 条验收断言体系、上线检查单 |
| **产出模块** | `semi/25_capstone/`（capstone.sh + acceptance_suite/run_all.sh 12 断言；data_backup/ 归档位） |
| **技术栈** | 全部前置项目的集合 |
| **前置** | 项目 1-24 全部 |
| **验收标准** | ① capstone.sh bootstrap 按依赖序重放 01-24 全部 up（幂等，实测多轮）；② acceptance 12 条断言全过（实测 2026-11-01：平台/组树/载体/农场/私仓/流水线绿/Release/制品/安全/回归/备份/度量 逐条 [ok]） |

**🤖 开始提示词**：
> `我要开始半导体 DevOps 终极项目「平台一键上线验收」。请给我完整内容约 300 行：capstone.sh bootstrap 按依赖序重放 01-24 全部 up（GitLab→组织/LFS→MR 集成→载体→农场→回归→发布链→生产化）+ acceptance_suite/run_all.sh 12 条断言（结构/供给/行为/资产/安全/韧性/度量分层）。附验收命令。只输出代码。`

**完成日期**：2026-11-01
**踩坑记录**：acceptance 双复合断言（A && ok || B && ok）两臂都过会双计数——展示噪音、判定以任一路径存在为准；bootstrap 重放期间 GitLab 重启窗口会让并行触发抖动（等就绪再触发）；平台验收 12 条与 P20 三层定位法同构（结构/供给/行为分层）；详见 `semi/25_capstone/README.md`

---

## 📅 周计划

| 周次 | 内容 | 项目数 |
|:---|:---|:---:|
| **第 1 周** | 项目 1-3（平台上线 / 组织权限 / LFS 载体） | 3 |
| **第 2 周** | 项目 4-5（⛓️平台验收 / Runner 资源池） | 2 |
| **第 3 周** | 项目 6-7（EDA 镜像 / kind 农场） | 2 |
| **第 4 周** | 项目 8-10（lint / 单元仿真 / 缓存加速） | 3 |
| **第 5 周** | 项目 11-12（⛓️MR 全流水线 / 种子回归矩阵） | 2 |
| **第 6 周** | 项目 13-14（夜间回归 / License 门禁） | 2 |
| **第 7 周** | 项目 15-16（Slurm 攻坚选做 / 回归仪表盘） | 2 |
| **第 8 周** | 项目 17-18（FPGA 综合 / 制品治理） | 2 |
| **第 9 周** | 项目 19-20（发布工程 / ⛓️全链演练） | 2 |
| **第 10 周** | 项目 21-22（安全加固 / 气隙供给） | 2 |
| **第 11 周** | 项目 23-24（备份容灾 / DORA 度量） | 2 |
| **第 12 周** | 项目 25（🏁 一键上线验收） | 1 |

## 🏆 里程碑

- [x] **完成项目 1-4** → 「内网平台管理员」：自托管 GitLab 生产可用，组织权限与 IP 保护落地
- [x] **完成项目 5-7** → 「农场架构师」：标签资源池 + 标准镜像 + 弹性农场
- [x] **完成项目 8-11** → 「第一条芯片流水线」：MR 驱动的 lint/仿真门禁体系
- [x] **完成项目 12-16** → 「回归农场操盘手」：种子矩阵、夜间回归、License 门禁、质量看板（半导体 CI 的核心辨识度）
- [x] **完成项目 17-20** → 「硬件发布工程师」：RTL → bitstream → 签名制品 → 客户交付包
- [x] **全部完成** → 「平台上线负责人」：从一台空 Mac 到生产级半导体 DevOps 平台的一键重放能力

## 📝 每日日志

| 日期 | 项目 | 耗时 | 收获 | 踩坑 |
|:---|:---|:---:|:---|:---|
| | | | | |

## 🔧 环境配置

```bash
# 0. 已就绪（实测持续更新）
#    Docker 29.8.2 + OrbStack（64GB RAM / 18 cores）、git-lfs、syft 1.51.1、kind 0.32.0、
#    iverilog 13.0 + cocotb 2.1.0（项目 3 冒烟仿真通过）、python-gitlab 8.6、pyyaml
#    镜像架构实测：gitlab/gitlab-ce 与 gitlab/gitlab-runner 均含 arm64；GitLab CE 19.5.3 已上线
#
# 1. 需安装：EDA 工具链剩余（阶段三/五用）
brew install verilator yosys nextpnr-ice40 icestorm
#    兜底：brew nextpnr-ice40 异常时 → pip install yowasp-yosys yowasp-nextpnr-ice40

# 2. 需安装：发布与 K8s（阶段五/二用）
brew install cosign kubectl             # syft 已就绪；kind 已就绪

# 3. Docker 镜像（阶段一/二，统一走国内镜像加速）
docker pull docker.1ms.run/gitlab/gitlab-ce:latest      # ⚠️ 大层 1.5GB 国内源易断流：失败就走 semi/01_gitlab_up/README.md 坑 1 的续传方案
docker pull docker.1ms.run/gitlab/gitlab-runner:latest
docker pull docker.1ms.run/library/registry:2

# 4. 每项目开工前：统一检查
docker info --format '{{.ServerVersion}}' && git lfs version && python3 -c "import cocotb" && curl -sf http://localhost:28200/-/readiness | grep -o healthy

# 5. 本清单端口占用（全系列分配表见根 README，已登记 28200-28279 段）
#    28200 GitLab HTTP | 28222 GitLab SSH | 28210 GitLab Pages
#    28250 GitLab Registry | 28252 mirror 私仓 | 28261 license-mock
```

## ⚠️ 与已有清单的关系

| 已有清单 | 关系 |
|:---|:---|
| **devops.md**（30/30） | 互补不重复：labs 16-20 已用 Jenkins/Gitea Actions/Woodpecker 学过 CI 基础概念（触发器/stage/artifact），本清单平台换自建 GitLab 后这些概念只复用不重讲；labs 13-14 的 Registry 治理与 cosign 签名在项目 18 直接当已知技能用；labs 21 Flux GitOps 与服务部署不在本清单（半导体 CI 主线是批处理作业，不是服务部署） |
| **cicd.md**（15/16） | 平台互补线：那条是 GitHub Actions 进阶（act/部署策略/供应链），本条是自建 GitLab + 半导体领域。cicd.md 项目 14 flaky 治理与本清单项目 13 方法论同源，但这里是「种子回归版」且带 child pipeline 重跑，做了不亏；GitHub/act 相关项目全部跳过 |
| **devsecops.md**（0/30） | 视角不同：本清单项目 21 只做「流水线平台的」安全（variables/runner/artifact 可见性）；SAST、镜像漏洞扫描、运行时安全等纵深内容全归 devsecops，两清单可先后做 |
| **pulumi.md / cloudify.md** | 无重叠：kind 在项目 7 作为被消费的基础设施直接复用 pulumi.md 攒下的经验，IaC/编排内容不出现 |

## 🔬 能力覆盖速查表（实测结论）

| 能力 | 计划 | 实测结论 |
|:---|:---|:---|
| GitLab CE on macOS ARM | docker.1ms.run 拉取 + 4.5GB 内存限额 | ✅ 容器实跑通过（2026-10-29：10 服务全 run、稳态 ~3GiB）；镜像获取 Plan B 见 `semi/01_gitlab_up/README.md` 坑 1 |
| GitLab 健康端点 | /-/readiness 轮询就绪 | ❌ 新版 CE 默认下线（实测 404）→ 就绪信号改 `users/sign_in` 200 + `/api/v4/version` 401（项目 1 实测） |
| GitLab 全局 server hooks | custom_hooks_dir 指向目录放裸 hook 文件 | ❌ GitLab 19 裸文件不被扫描 → 必须放 `custom_hooks/pre-receive.d/` 子目录 + 属主 git:git（项目 2 实测；per-repo 旧式 `custom_hooks/` 反而仍兼容） |
| GitLab Runner | docker executor + K8s executor | ✅ arm64 manifest 实测存在（K8s executor 对 kind 兼容性 ⚠️ 项目 7 探活，有降级方案） |
| verilator | brew / apt 双路径 | ✅ brew 5.052 bottled |
| yosys | brew / apt 双路径 | ✅ brew 0.70 bottled |
| nextpnr-ice40 | brew formula + yowasp pip 兜底 | ✅ formula 存在（chipdb 完整性 ⚠️ 项目 17 探活，兜底实测有 pip 包） |
| iverilog + cocotb | brew iverilog + pip cocotb 2.1.0 | ✅ cocotb cp313 macOS arm64 wheel 实测可拉（iverilog VPI 联动 ⚠️ 项目 9 探活，可固定 cocotb 1.9.2 或换 verilator 后端） |
| Slurm in Docker | 自建 ubuntu+slurm-wlm 镜像 | ⚠️ 待探活（现成 arm64 镜像稀缺）；失败则降级队列模拟器，学习目标不变 |
| GitLab Pages 本机 | Omnibus pages_external_url | ⚠️ 待探活；失败降级旁挂 nginx，知识补文档 |
| GitLab CE Premium 功能 | push rules / 多审批规则 | ❌ 不可用（License 限制）→ 已用 server hooks / 基础 approvals 等效替代（项目 2 知识点本身） |
