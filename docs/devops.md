# 🛠️ DevOps 工具链 30 小项目学习清单 · Todo List（本机全跑通）

> 一条完整 DevOps 流水线的搭建与演练：**IaC → 配置管理 → 镜像/制品 → CI/CD → GitOps/策略 → 可观测/漂移**
> 覆盖工具：Terraform · Ansible · Puppet · Salt · Chef/InSpec · Packer · Jenkins · Gitea Actions ·
> Woodpecker · Flux · OPA/Conftest · tfsec/trivy · SOPS/Vault · Prometheus/Loki/Grafana
> **零云依赖**：Docker 容器当被管节点（"靶场环境"），macOS 本机全部可跑、全部免费
> 每项目 100-300 行；⛓️ 集成点项目把各工具串进同一条流水线；项目 30 终极串联
> 预计周期：8-9 周（每天 2-3 小时）

## 🏗️ 终极蓝图（项目 30 完成时）

```
 git push ──▶ Gitea/Jenkins/Woodpecker (CI)
               │ 测试 → Packer 构建 → 推私有 Registry
               │ Conftest/tfsec/密钥检查 三道门 (25)
               ▼
          Flux GitOps (21) ──▶ 靶场环境 (Terraform 拉起 ①)
               │                  ├─ nginx / app 容器
               │                  ├─ Ansible/Salt/Chef/Puppet 配置管理 (6-10)
               │                  └─ Registry/MinIO 基础设施
               ▼
   Prometheus + Loki + Grafana (26-27) ←─ 漂移检测 (28) / 备份恢复演练 (29)
```

## 🤖 AI 辅助提示词速查

| 场景 | 提示词 |
|:---|:---|
| **开始一个新项目** | `我要开始 DevOps 项目「[名称]」，被管对象是本机 Docker 容器（靶场环境）。请给我完整代码/配置约 [行数] 行（[工具]），macOS 可运行，附验收命令。只输出代码。` |
| **流水线排障** | `我的 [Jenkins/Gitea Actions/Flux] 流水线在 [阶段] 失败：[日志粘贴]。请分析根因并给修复后的完整配置。` |
| **工具对比** | `对比 [工具A] 和 [工具B] 在 [场景] 的差异（模型/状态/生态/适用规模），给出什么时候选谁。` |

## 📊 总进度

进度：██░░░░░░░░░░░░░░░░░░ 0/30 (0%)

| 阶段 | 项目数 | 已完成 |
|:---|:---:|:---:|
| 第一阶段：IaC 深水区（Terraform） | 5 | 0 |
| 第二阶段：配置管理四大代际 | 5 | 0 |
| 第三阶段：镜像与制品 | 5 | 0 |
| 第四阶段：CI/CD 流水线 | 5 | 0 |
| 第五阶段：GitOps、策略与安全 | 5 | 0 |
| 第六阶段：可观测、漂移与终极交付 | 5 | 0 |
| **合计** | **30** | **0** |

---

## 🗂️ 第一阶段：IaC 深水区——Terraform（项目 1-5）

> **目标**：从会 apply 到真工程：模块、状态、多环境；续接 `terraform.md` 已完成的 3/10 基础

### [x] 项目 1：Docker Provider——用 TF 管容器

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 .tf |
| **核心知识点** | docker provider、resource 依赖图、plan/apply/destroy 幂等、`terraform state list/show` |
| **验收标准** | TF 拉起 nginx 容器 + 自定义网络；手动 `docker stop` 后 plan 能检出漂移；destroy 全清 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 1「TF Docker Provider」。请给我 .tf 约 120 行：docker provider 管 nginx 容器+网络+卷，演示 plan 漂移检测与 state 查看。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 2：模块化 + 本地 Registry 引用

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 .tf |
| **核心知识点** | module 输入输出、`for_each` 多实例、模块目录规范、tflint 静态检查 |
| **产出物** | `modules/web-service`（容器+卷+健康检查），两处引用实例化两套服务 |
| **验收标准** | 改一处 module 两实例同步更新；tflint 零告警；`terraform graph` 贴进 README |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 2「TF 模块化」。请给我约 200 行 .tf：可复用 web-service module（for_each 双实例）、tflint 配置与运行、terraform graph 输出。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 3：状态管理深潜

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 .tf + 脚本 |
| **核心知识点** | 远端 S3 后端（Docker 起 MinIO 当 S3）、state 锁、`state mv/rm/import`、敏感值处理（sensitive）|
| **验收标准** | state 存 MinIO 且有锁文件；`state mv` 重命名资源不重建；两人（两目录）同时 apply 演示锁互斥 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 3「状态深潜」。请给我约 150 行：docker 起 MinIO 做 S3 backend（含 bucket 自动建）、state mv/import 演示、锁互斥实验脚本。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 4：多环境矩阵（workspace vs 目录法）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 .tf |
| **核心知识点** | workspaces + tfvars、目录法（envs/dev,staging）、两种组织法优劣、条件表达式切换配置 |
| **验收标准** | dev/staging 两环境参数不同（端口/镜像版本/副本数）各自独立 apply；对比表写清何时用哪种 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 4「多环境」。请给我约 180 行 .tf：workspace 法与目录法各实现 dev/staging（参数化端口/镜像/副本），附两法对比表。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] ⛓️ 项目 5：集成点①——Terraform 靶场环境

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 .tf |
| **核心实现** | 一键拉起后续项目的被管对象：`devops-lab`（nginx 应用 + registry:2 + MinIO + Gitea 数据卷），`make lab-up/down` |
| **验收标准** | `make lab-up` 一条命令全套就绪；`terraform destroy` 全清；输出 endpoints 清单 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 5「集成点①靶场」。请给我约 200 行 .tf：一键拉起 nginx+registry+MinIO+Gitea 容器组，Makefile 的 lab-up/down，输出 endpoints。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第二阶段：配置管理四大代际（项目 6-10）

> **目标**：Ansible 进阶 + 亲手跑 Salt/Chef/Puppet——理解四代配置管理的设计取舍（续接 `ansible.md` 3/10）

### [x] 项目 6：Ansible 深水区（Role + Vault + 动态清单）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心知识点** | role 目录规范、ansible-vault 加密变量、动态 inventory（docker 容器自动发现）、幂等与 changed 判定 |
| **验收标准** | role 管理 nginx 配置到靶场容器（docker connection）；vault 加密的密码参与渲染；重复跑全绿零 changed |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 6「Ansible 深水区」。请给我约 250 行：nginx role+vault 加密变量+docker 动态 inventory，幂等验证与 vault 使用流程。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 7：Molecule——给 Role 写测试

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | Molecule + docker driver、idempotence 测试、verify（ansible 断言）、CI 里跑 role 测试的姿势 |
| **验收标准** | `molecule test` 全绿：创建→converge→幂等→验证→销毁；故意写坏 role 让测试变红一次 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 7「Molecule」。请给我约 180 行：nginx role 的 molecule 场景（docker driver、幂等与验证测试），附故意失败的演示。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 8：SaltStack 主从与 masterless

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 SLS |
| **核心知识点** | state.sls 声明式、pillar/grain、masterless 模式（`salt-call --local`）、与 Ansible 的 pull/push 模型差异 |
| **验收标准** | masterless 管理 nginx 容器内配置达到与项目 6 等效效果；对比表：push vs pull、agent vs agentless |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 8「Salt」。请给我约 200 行：masterless salt-call 管理 nginx 容器配置，pillar 分环境，附与 Ansible 模型差异对比表。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 9：Chef 本地模式 + InSpec 合规扫描

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行（cookbook + inspec profile）|
| **核心知识点** | cookbook/recipe/resource、chef-solo local-mode、InSpec 控件（describe/it）、合规即代码 |
| **验收标准** | cookbook 配好 nginx；InSpec 扫描靶场输出合规报告（通过/失败控件清单）；修一个失败控件变绿 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 9「Chef+InSpec」。请给我约 200 行：nginx cookbook（chef-solo 本地模式跑容器内）+ InSpec profile 扫描，附修复失败控件演示。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 10：Puppet（⚠️ 探活 + fallback 预案）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行（manifest + compose）|
| **核心知识点** | 声明式 DSL、agent-master 模型、catalog 编译、Facter facts；四代配置管理总对比（Ansible/Salt/Chef/Puppet）|
| **核心实现** | Docker 起 puppetserver+puppet-agent 双容器，manifest 管理 nginx 配置，agent 定时拉取 catalog |
| **⚠️ 探活预案** | 官方镜像 arm64 支持待验证：先 `docker pull puppet/puppetserver` 试跑；失败则降级 `puppet/puppet-agent` 单容器 `puppet apply` 模式（保 DSL 学习目标），如实记录 |
| **验收标准** | agent 拉到 catalog 且 nginx 配置生效；输出四代工具总对比表（架构/语言/伸缩/适用规模）|

**🤖 开始提示词**：
> `我要开始 DevOps 项目 10「Puppet」。请给我约 200 行：docker-compose 起 puppetserver+agent（附 arm64 探活与 puppet apply 降级方案），nginx manifest，四代配置管理对比表。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第三阶段：镜像与制品（项目 11-15）

> **目标**：交付物的工程化：瘦身、构建、私有仓库、版本化与供应链

### [x] 项目 11：镜像瘦身与多架构构建

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行（Dockerfile×3 + 脚本）|
| **核心知识点** | 多阶段构建、层缓存优化、dive 分析层、buildx 多架构（linux/amd64+arm64）|
| **验收标准** | 同一应用三个版本镜像体积对比表（如 900MB→150MB）；多架构镜像 manifest 推送成功 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 11「镜像瘦身」。请给我约 120 行：同一应用三版 Dockerfile（单阶段/多阶段/distroless）、dive 分析命令、buildx 多架构构建推送脚本。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 12：Packer 镜像流水线

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 HCL |
| **核心知识点** | Packer HCL2、docker builder、provisioner（shell/ansible!）、post-processor 推 registry——IaC 思想做镜像 |
| **验收标准** | `packer build` 产出镜像自动推到靶场 registry；provisioner 用 Ansible 复用项目 6 的 role（打通 TF-ansible-packer）|

**🤖 开始提示词**：
> `我要开始 DevOps 项目 12「Packer」。请给我约 150 行 HCL：docker builder + ansible provisioner（复用 nginx role）+ 推私有 registry，附 build 与验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 13：私有 Registry 治理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（compose + 脚本）|
| **核心知识点** | registry:2 配置（认证/存储）、垃圾回收 GC、标签保留策略、`docker login` 流程 |
| **验收标准** | 带基本认证的私有 registry 推拉成功；GC 后磁盘占用下降可量化；写出保留策略规则并脚本化清理 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 13「Registry 治理」。请给我约 150 行：带认证的 registry compose、GC 与磁盘对比、按标签保留策略的清理脚本。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 14：制品版本化 + SBOM + 签名

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（脚本）|
| **核心知识点** | semver vs digest 引用、syft 生成 SBOM、cosign 签名与验签、供应链安全入门 |
| **验收标准** | 镜像带 SBOM + 签名发布；篡改镜像后验签失败可演示；CI 可用的一条验签命令产出 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 14「SBOM+签名」。请给我约 150 行脚本：syft 生成 SBOM、cosign 签名/验签、篡改演示，附 CI 可用的验证命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] ⛓️ 项目 15：集成点②——手工发布流水线

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行（Makefile + 脚本）|
| **核心实现** | 串 11-14：代码变更 → 构建（多阶段）→ SBOM+签名 → 推 registry → 部署到靶场（TF/ansible 二选一切换）；`make release VERSION=x` |
| **验收标准** | 一条命令完成 发布全流程；每个环节产物可追溯（镜像 digest + SBOM + 签名记录）|

**🤖 开始提示词**：
> `我要开始 DevOps 项目 15「集成点②发布流水线」。请给我约 200 行：make release 串联 构建/SBOM/签名/推送/部署，产物可追溯清单输出。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第四阶段：CI/CD 流水线（项目 16-20）

> **目标**：三大 CI 体系各来一遍：Jenkins（老牌）+ Gitea Actions（轻量 Git 平台）+ Woodpecker（容器原生）

### [x] 项目 16：Jenkins 基础（Pipeline as Code）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（Jenkinsfile + compose）|
| **核心知识点** | Jenkins LTS 容器化、声明式 Pipeline、stage/agent/post、把项目 15 的 release 变成 Jenkins job |
| **验收标准** | Web UI 触发构建全流程绿；失败 stage 标红且有日志；Jenkinsfile 入 git 库 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 16「Jenkins 基础」。请给我约 150 行：jenkins LTS compose、声明式 Jenkinsfile 跑 release 流水线（docker 命令挂载 docker.sock），附验收步骤。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 17：Jenkins 深水区（Shared Library + 并行 + 凭据）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行（Groovy）|
| **核心知识点** | Shared Library 抽公共逻辑、并行 stage、credentials 管理（registry 密码不进日志）、docker agent 隔离构建环境 |
| **验收标准** | registry 凭据走 credentials（日志无明文）；构建/测试两 stage 并行耗时≈串行一半；公共步骤抽成 library 被两个 Jenkinsfile 复用 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 17「Jenkins 深水区」。请给我约 200 行 Groovy：Shared Library、并行 stage、credentials 绑定 registry、docker agent，附凭据不泄露验证。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 18：Gitea + Actions 轻量 Git 平台

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行（compose + workflow yaml）|
| **核心知识点** | Gitea 容器 + act_runner 注册、GitHub Actions 兼容语法、push 触发 → 自动跑 release 流水线 |
| **验收标准** | git push 自动触发：测试→构建→部署靶场全绿；PR 页面看到 checks 状态；本地 act 单跑 workflow 调试法产出 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 18「Gitea Actions」。请给我约 200 行：gitea+act_runner compose、workflow yaml 跑 release（含 docker/registry 访问），push 触发验收步骤。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 19：Woodpecker 容器原生 CI（对比项）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（compose + yaml）|
| **核心知识点** | Woodpecker 架构（server+agent 容器）、极简 pipeline 语法、与 Gitea/Jenkins 的取舍 |
| **验收标准** | 同一 release 流水线在 Woodpecker 跑绿；三 CI 对比表（学习成本/生态/资源占用/插件模型）|

**🤖 开始提示词**：
> `我要开始 DevOps 项目 19「Woodpecker」。请给我约 150 行：woodpecker server+agent compose 接 Gitea，同语义 release pipeline，附三 CI 对比表。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] ⛓️ 项目 20：集成点③——完整 CI/CD

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心实现** | 主流水线定型（选 Gitea Actions 为主，Jenkins 备用）：push → 单测 → 构建 → SBOM+签名 → 推 registry → 部署靶场 → 冒烟验证 → 通知；失败任一环节全链路阻断 |
| **验收标准** | 从 git push 到新版本跑在靶场 ≤5 分钟全自动；故意注入失败用例验证阻断；每次发布留痕（commit↔镜像 digest 映射表）|

**🤖 开始提示词**：
> `我要开始 DevOps 项目 20「集成点③完整CI/CD」。请给我约 200 行：定型主流水线（含冒烟与通知）、失败注入验证脚本、commit-镜像追溯清单生成。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第五阶段：GitOps、策略与安全（项目 21-25）

> **目标**：部署声明化、策略门禁、密钥治理——现代交付的"安全左移"

### [x] 项目 21：Flux GitOps（kind 上）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行（kustomize + 脚本）|
| **核心知识点** | Flux sources/kustomization、拉模型 vs 推模型、镜像自动化（ImageUpdateAutomation）、与 ArgoCD 对比（k8s 系列项目 28）|
| **验收标准** | git push 镜像 tag → kind 集群自动滚动更新；README 写清 pull vs push 模型与安全差异 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 21「Flux GitOps」。请给我约 200 行：flux bootstrap 到 kind、kustomize 部署靶场应用、ImageUpdateAutomation 自动改 tag，附与 ArgoCD 对比。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 22：策略即代码（OPA/Conftest）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行（Rego）|
| **核心知识点** | Rego 规则、conftest test terraform plan/K8s manifests、违规输出友好化、策略分层（禁止 latest tag/必须资源限制/禁 0.0.0.0）|
| **验收标准** | ≥6 条策略：坏配置全被拦且报错可读、好配置全过；把 conftest 接进项目 20 流水线做门禁 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 22「OPA 策略」。请给我约 180 行：conftest+Rego 策略集（latest 禁用/资源限制/端口白名单等 ≥6 条），对 TF plan 与 K8s manifest 双验收，接 CI 门禁。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 23：IaC 安全扫描三件套

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（脚本 + 坏配置样本）|
| **核心知识点** | tfsec（TF 静态扫描）、trivy config、tflint；故意埋 10 个坏配置（明文密钥/开放安全组/过期 TLS）检出率验证 |
| **验收标准** | 10 个坏配置 ≥9 个被扫出（报告归类 CRITICAL/HIGH）；扫描接入流水线（CRITICAL 阻断）|

**🤖 开始提示词**：
> `我要开始 DevOps 项目 23「IaC 扫描」。请给我约 150 行：埋 10 个坏配置的 TF/manifest 样本 + tfsec/trivy/tflint 扫描脚本 + 报告归类，接 CI 阻断。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 24：密钥治理（SOPS+age，对照 Vault）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | SOPS 加密 yaml 可入 git、age 密钥、编辑/解密流程、与 Vault 动态密钥的选型边界（衔接 k8s 项目 22）|
| **验收标准** | 加密后的 secrets.yaml 入 git（扫描无明文）；CI 用 age 私钥解密部署成功；选型对比表（静态加密 vs 动态注入）|

**🤖 开始提示词**：
> `我要开始 DevOps 项目 24「SOPS」。请给我约 150 行：SOPS+age 加密部署密钥、CI 解密流程、明文扫描验证、与 Vault 选型对比表。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] ⛓️ 项目 25：集成点④——合规流水线

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心实现** | 流水线加三道门：策略门（conftest）→ 安全门（tfsec/trivy CRITICAL 阻断）→ 密钥门（明文扫描 + 签名验签）；门禁报告 artifact 化 |
| **验收标准** | 三道门各注入一次违规均被拦且报告可下载；全绿时流水线耗时增幅 ≤30% |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 25「集成点④合规流水线」。请给我约 180 行：三道门接入 + 违规注入验证 + 门禁报告 artifact，含耗时对比。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第六阶段：可观测、漂移与终极交付（项目 26-30）

> **目标**：看得见、防得住、 recover 得了，最后串成完整 DevOps 一体机

### [x] 项目 26：监控栈（Prometheus + Grafana 盯自己的流水线）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行（prometheus.yml + dashboards）|
| **核心知识点** | Prometheus 抓取配置（jenkins/gitea/registry 的 /metrics）、Grafana 导入 dashboard、告警规则（构建失败率/队列积压）→ webhook 通知 |
| **验收标准** | 三条曲线可见（构建次数/时长/成功率）；一条告警规则真实触发到 webhook；⚠️ cAdvisor 在 Docker Desktop 上受限，用应用级 metrics 替代（如实记录）|

**🤖 开始提示词**：
> `我要开始 DevOps 项目 26「监控栈」。请给我约 180 行：prometheus 抓 jenkins/gitea/registry metrics、Grafana 面板 JSON、构建失败告警→webhook 规则。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 27：集中日志（Loki 轻量栈）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | Loki+Promtail+Grafana、docker 日志采集、LogQL 查询、告警（ERROR 速率）|
| **验收标准** | 靶场与 CI 容器日志集中在 Grafana 可查；LogQL 统计 ERROR 速率并配一条告警 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 27「Loki 日志」。请给我约 150 行：loki+promtail compose 采 docker 日志、LogQL 查询与 ERROR 告警、Grafana 数据源配置。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 28：配置漂移检测与治理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行（脚本）|
| **核心实现** | 三种漂移源实测：手动改容器配置 / docker 手动重建 / registry 里镜像被覆盖；TF plan -detailed-exitcode 与 Ansible --check 双探针；一键回正（TF apply / ansible 播放）|
| **验收标准** | 注入 3 类漂移均被检出并定位；一键回正后系统与期望态一致；漂移治理 SOP 文档（检测→定位→修复→复盘）|

**🤖 开始提示词**：
> `我要开始 DevOps 项目 28「漂移治理」。请给我约 200 行：三类漂移注入+双探针检测（TF plan/ansible --check）+一键回正脚本+SOP 文档。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 项目 29：备份与灾难恢复演练

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行（脚本）|
| **核心实现** | 全量备份清单：靶场卷数据 + TF state（MinIO）+ Gitea 仓库 + registry 存储；`make backup` 打包 → `make destroy-all` 模拟灾难 → `make restore` 恢复；RTO/RPO 实测计时 |
| **验收标准** | 恢复后端到端冒烟全绿（应用可访问/CI 可跑）；RTO/RPO 有实测数字；备份清单文档化"什么必须备份、什么可重建" |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 29「备份恢复」。请给我约 200 行：backup/restore 脚本（卷+state+Gitea+registry）、destroy-all 灾难演练流程、RTO/RPO 计时输出。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [x] 🏁 项目 30：终极串联——DevOps 一体机

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~300 行（Makefile + compose 汇总 + 文档）|
| **核心实现** | `make up` 一键拉起整套：靶场(TF) + Gitea/Jenkins(CI) + Flux(kind) + 监控日志 + registry；`make demo` 讲完整故事：改一行代码 push → 自动构建过三道门 → GitOps 滚动更新 → Grafana 看到发布曲线 → 注入漂移被 28 检出 → 灾难恢复演示；README 含工具栈对照表（本机栈 vs 企业栈：云/Terraform Cloud、GitLab、Datadog、Harbor…）|
| **验收标准** | 全新机器按 README 从零到 `make demo` 跑通 ≤30 分钟；故事线 6 环节全程无手工干预；对照表覆盖每类工具的企业级替代 |
| **前置** | 项目 1-29 |

**🤖 开始提示词**：
> `我要开始 DevOps 项目 30「终极串联」。请给我约 300 行：总 Makefile+compose 汇总一键拉全套、make demo 六环节故事线脚本、README 从零安装指南与企业栈对照表。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 📅 周计划

| 周次 | 内容 | 项目数 |
|:---|:---|:---:|
| **第 1-2 周** | 项目 1-5（Terraform 深水区 + 靶场）| 5 |
| **第 3 周** | 项目 6-7（Ansible 进阶 + Molecule）| 2 |
| **第 3-4 周** | 项目 8-10（Salt/Chef/Puppet 四代对比）| 3 |
| **第 4-5 周** | 项目 11-15（镜像制品 + 发布流水线）| 5 |
| **第 5-6 周** | 项目 16-20（三大 CI + 完整流水线）| 5 |
| **第 7 周** | 项目 21-25（GitOps/策略/安全/密钥）| 5 |
| **第 8-9 周** | 项目 26-30（可观测/漂移/灾备/一体机）| 5 |

## 🏆 里程碑

- [ ] **项目 1-5** → Terraform 工程能力（模块/远端状态/多环境）+ 靶场环境一键化
- [ ] **项目 6-10** → 四代配置管理亲历（Ansible/Salt/Chef/Puppet）+ role 可测试
- [ ] **项目 11-15** → 制品工程能力（瘦身/Packer/Registry/SBOM 签名）+ 手工发布线
- [ ] **项目 16-20** → 三大 CI 体系实战 + push 即部署的完整流水线
- [ ] **项目 21-25** → GitOps + 三道合规门（策略/扫描/密钥）+ Flux 自动化
- [ ] **项目 26-30** → 监控日志 + 漂移/灾备演练 + **DevOps 一体机一键 demo**
- [ ] **全部完成** → 能独立设计一套企业级 DevOps 平台并说清每个工具的选型理由

## 📝 每日日志

| 日期 | 项目 | 耗时 | 收获 | 踩坑 |
|:---|:---|:---:|:---|:---|
| | | | | |

## 🔧 环境配置

```bash
# 0. 已就绪：docker / ansible / terraform / kind（验证：docker info && terraform version && ansible --version）

# 1. IaC 与扫描（阶段一、五）
brew install tflint tfsec trivy conftest opa jq yq

# 2. 配置管理（阶段二）
pip3 install molecule molecule-plugins[docker]   # 项目 7
pip3 install salt                                 # 项目 8（masterless）
brew install --cask chef-workstation              # 项目 9（chef/inspec）
# 项目 10 Puppet 走 docker 镜像，无需本机安装

# 3. 制品与供应链（阶段三）
brew install packer syft cosign                   # 项目 12/14

# 4. CI/GitOps（阶段四、五）
# Jenkins/Gitea/Woodpecker 全部 docker compose，无需本机安装
brew install fluxcd-cli                           # 项目 21（或 brew install fluxcd/tap/flux）
brew install sops age                             # 项目 24

# 5. 监控日志（阶段六）
# Prometheus/Grafana/Loki 全部 docker compose

# 6. 每项目开工前
docker info && make lab-up   # 靶场就绪（项目 5 之后）
```

## ⚠️ 与已有清单的关系

| 已有清单 | 关系 |
|:---|:---|
| `_todo/terraform.md`（3/10）| 单工具入门线（provider/变量/数据源已完成）；本清单阶段一直接进阶工程化，**重复的入门项目跳过** |
| `_todo/ansible.md`（3/10）| 单工具入门线（adhoc/playbook/变量/模板已完成）；本清单项目 6-7 是它的进阶篇 |
| `_todo/devops_interview.md`（9/10）| 面试八股向；本清单是动手平台向，其知识点可在本清单找到实验对应 |
| `_todo/kubernetes.md`（31/31 完成）| K8s 深度线；本清单项目 21 Flux 与其 ArgoCD（项目 28）互补，监控项目 26/27 与其 23/24 分层不同（本机工具链 vs 集群内）|
| `_todo/aws.md`（10/30）| 云技能线；本清单的 TF 工程化直接复用到其项目 24-25（TF 工程化）|
