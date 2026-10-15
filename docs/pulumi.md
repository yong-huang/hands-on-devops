# ⚡ Pulumi 12 小项目学习清单 · Todo List（TS 主线 · 零云三 Provider）

> 通过 12 个小项目（每项目 100-200 行 TypeScript/Python）快速上手 Pulumi：CLI 回路 → 组件与测试 → Docker/kind/LocalStack 多 Provider 混合编排 → CI 交付闭环
> 约束：本机 macOS + Docker 全跑通、**零云依赖**（kind 与 LocalStack 本机模拟）、全部免费；TypeScript 为主线，项目 7 用 Python 同题对照
> 串联机制：阶段即能力等级——核心工作流 → 工程化 → 多 Provider 交付；项目 11 ⛓️ 一次跨三栈混合编排，项目 12 🏁 preview 门禁接进 CI 收口
> 预计周期：4 周（每天 2-3 小时）
> 定位：**devops.md 的互补线**——项目 1-5 已用 Terraform 打过 IaC 地基，本清单同题换 Pulumi 视角对照，不重复讲 IaC 概念本身（关系见文末）

## 🤖 AI 辅助提示词速查

| 场景 | 提示词 |
|:---|:---|
| **开始一个新项目** | `我要开始 Pulumi 项目「[名称]」（TypeScript，macOS + Docker/kind/LocalStack 本机可跑、零云）。请给我完整代码约 [行数] 行，附验收命令。只输出代码。` |
| **排障** | `我的 Pulumi 程序出现 [现象]，报错/up 输出：[粘贴]。请分析根因并给修复后的完整代码。` |
| **概念对照（与 TF 并读）** | `对照我在 Terraform 里的做法：[粘贴 TF 代码]，请给出等价的 Pulumi TypeScript 写法，并指出两者状态模型与依赖推断的差异。` |
| **Output 类型纠错** | `这段 Pulumi TS 代码报 Output 类型错误：[代码/报错]。请解释原因并用 apply / pulumi.all 正确改写。` |

## 📊 总进度

进度：████░░░░░░░░░░░░░░░░ 4/12 (33%)

| 阶段 | 项目数 | 已完成 |
|:---|:---:|:---:|
| 第一阶段：核心工作流——CLI 回路与编程模型对照 | 4 | 3 |
| 第二阶段：工程化——组件、测试与编程模型 | 4 | 0 |
| 第三阶段：多 Provider——K8s/AWS 与交付闭环 | 4 | 0 |
| **合计** | **12** | **3** |

---

## 🗂️ 第一阶段：核心工作流——CLI 回路与编程模型对照（项目 1-4）

> **目标**：跑通 `pulumi new → up → destroy` 回路，建立「TF 声明式 DSL ↔ Pulumi 通用语言」概念映射，state 能自主托管到自建 S3

### [x] 项目 1：第一个程序——Docker Provider 与 CLI 回路

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~100 行 TypeScript |
| **核心知识点** | `pulumi new`（docker-typescript 模板）、项目/程序/栈三层概念、`up/preview/destroy` 回路、Docker provider 管 nginx 容器 + 自定义网络 |
| **技术栈** | Pulumi CLI 3.268（⚠️ 需安装）+ Node 22 + @pulumi/docker 5.2.0（npmmirror 已实测可装） |
| **验收标准** | `pulumi up` 后 `docker ps` 见 nginx 容器；紧接着 `pulumi preview` 显示 0 change（幂等）；`pulumi destroy` 后容器与网络零残留 |
| **实验目录** | `pulumi/01_docker_provider/`（✅ `all` 全程 exit=0，OrbStack 引擎） |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「第一个程序」。请给我完整 TypeScript 代码约 100 行（@pulumi/docker）：nginx 容器 + 自定义网络，演示 pulumi new/up/preview/destroy 全回路（macOS + Docker 已就绪），附验收命令。只输出代码。`

**完成日期**：2026-10-15
**踩坑记录**：① 本地后端要预建状态目录（否则 `unable to open state directory`）、`stack init` 必须有 `PULUMI_CONFIG_PASSPHRASE`（否则 `passphrase must be set`）；② Pulumi 默认不刷新实际状态——裸 preview 对已删容器报 `3 unchanged`，需 `refresh` / `--refresh`（与 `terraform plan` 默认 refresh 的习惯不同）；③ 漂移形态差异：`docker stop` 后 refresh 记 mustRun 变更、up 走 replace；`rm` 后 refresh 报 delete、up 直接 create；④ 断言别在活管道上 `grep -q`（SIGPIPE 会造成"全绿却断言失败"），先落档再断言

---

### [x] 项目 2：编程语言的力量——循环/条件/函数 vs HCL

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 TypeScript |
| **核心知识点** | for 循环按数组批量建资源、条件表达式选镜像 tag、函数封装公共配置、tsc 类型检查拦截错误；HCL（count/for_each）与 TS 写法对照表 |
| **前置** | 项目 1 |
| **验收标准** | `WEB_SITES` 数组从 2 个加到 3 个，`pulumi up` 后容器数同步为 3；故意写错类型时 `npx tsc --noEmit` 报错拒绝；对照表写进实验 README |
| **实验目录** | `pulumi/02_language_features/`（✅ `all` 全程 exit=0，含 2→3→2 增量收敛与 TS2322 拦截） |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「编程语言的力量」。请给我完整 TypeScript 代码约 120 行：用 for 循环按数组批量建多站点容器、条件选择镜像 tag、函数封装公共配置，并附 HCL（count/for_each）与 TS 写法对照表。只输出代码。`

**完成日期**：2026-10-15
**踩坑记录**：① Pulumi 属性类型是 `Input<T>` 包装——类型错误原文是 `Type 'string' is not assignable to type 'Input<number | undefined>'`，按普通类型不匹配理解即可；② 资源逻辑名即身份：`site-${site.name}` 改名 = 删旧建新，别用数组下标拼逻辑名（删中间项会全体位移重建）；③ 无依赖资源并行创建（日志里 alpha/beta 同时 creating），期望态是依赖图不是顺序脚本；④ scale/fail 段确定性改写源文件的演示必须配退出守护（trap 还原），中断也不留脏状态

---

### [x] 项目 3：Stack 与配置——多环境 + Secrets

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 TypeScript |
| **核心知识点** | stack（dev/prod）概念与 `stack init/select/ls/rm`、`pulumi config set`、`--secret` 加密存储、config.getXxx 类型化读取、按 stack 分支参数（端口/镜像版本） |
| **前置** | 项目 1 |
| **验收标准** | dev/prod 两 stack 同程序各自 `pulumi up` 且端口/参数不同互不干扰；`pulumi config get` 对 secret 项输出密文（不落明文）；与 TF workspace 的对照笔记写进 README |
| **实验目录** | `pulumi/03_stack_config/`（✅ `all` 全程 exit=0；隔离/轮换/密文三层/零残留全断言） |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「Stack 与配置」。请给我完整 TypeScript 代码约 120 行：dev/prod 两个 stack 读取配置（端口/镜像版本各异），含 pulumi config set --secret 用法，演示 stack init/select/ls。只输出代码。`

**完成日期**：2026-10-15
**踩坑记录**：① 原验收「config get 对 secret 输出密文」与实测不符——`config get` 的设计就是给 CLI 用户看明文；保护边界是**落盘形态**：`Pulumi.<stack>.yaml` 与 `.pulumi-state/` 全量 grep 明文 0 命中，`up`/`config` 输出打码 `[secret]`，容器 env 运行时才解密注入；② 每栈独立 `encryptionsalt`，`PULUMI_CONFIG_PASSPHRASE` 是唯一解密钥匙（丢了密文永久解不开）；③ 同名逻辑名 `web` 靠 URN 带栈名隔离（`urn:pulumi:dev::…::web` ≠ `urn:pulumi:prod::…::web`），但 Docker 真名要自己按栈派生才不撞；④ `destroy` 只清资源不删栈（`stack ls` 仍见 RESOURCE COUNT 归零的栈），带资源 `stack rm` 被拒 `still has resources`；⑤ secret 轮换 = `config set --secret` + `up`，diff 只见 `~envs` 不见明文，走 replace

---

### [x] 项目 4：状态管理——本地文件 → MinIO S3 后端

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行（脚本 + 配置） |
| **核心知识点** | 本地 file backend 目录结构、`pulumi login s3://...`（docker 起 MinIO 当 S3，复用本仓库 labs/03 模式）、state 迁移（export/import）、`pulumi import` 接管已存在容器、`pulumi refresh` 检出漂移 |
| **前置** | 项目 1 |
| **验收标准** | state 迁到 MinIO 后 `pulumi up` 零 diff；手动 `docker rm -f` 一个容器后 `pulumi refresh` 检出漂移；`pulumi import` 接管手工创建的容器后 `pulumi destroy` 能全清 |
| **实验目录** | `pulumi/04_state_backend/`（✅ `all` 全程 exit=0，连跑两遍验证重跑幂等；零 diff/漂移检出/接管全清全断言） |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「状态管理」。请给我约 120 行：本地 file backend → MinIO s3:// backend 的登录与迁移脚本、pulumi import 接管已存在容器的命令序列、pulumi refresh 漂移检出演示（docker 起 MinIO 的方式参考本仓库 labs/03）。只输出代码。`

**完成日期**：2026-10-15
**踩坑记录**：① p-docker（@pulumi/docker）5.2.0 的 `import` 只认容器 64 位长 ID，给名字报 `resource does not exist`——先 `docker inspect --format '{{.Id}}'` 取 ID；② Pulumi 的 s3 backend **不认** `AWS_ENDPOINT_URL`/`AWS_S3_FORCE_PATH_STYLE` 环境变量（报 `InvalidBucketName`），端点与 path-style 只能写进 `s3://桶?endpoint=…&s3ForcePathStyle=true` 的 URL 查询参数；③ `pulumi -C program` 下 `stack import --file` 的相对路径相对 `program/` 解析，必须给绝对路径；④ MinIO 响应不带校验和会刷 SDK WARN，`AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED` 消音；⑤ 当期网络 mc 镜像三源全挂（ustc EOF/daocloud denied/quay 401），脚本兜底用宿主 aws CLI 建桶；⑥ `PULUMI_BACKEND_URL` 环境变量选后端等价 `pulumi login` 但不碰全局登录态（clean 零痕迹）；⑦ 自管后端（file/s3）无并发锁，协作要靠约定或上 Pulumi Cloud

---

## 🗂️ 第二阶段：工程化——组件、测试与编程模型（项目 5-8）

> **目标**：把 IaC 当程序写工程化——组件抽象、自动化测试、跨语言对照、Output 模型无盲区

### [ ] 项目 5：ComponentResource——对标 TF module

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 TypeScript |
| **核心知识点** | ComponentResource 类封装（容器 + 网络 + 端口输出）、args 输入/outputs 输出、子资源 parent/URN 树、一个组件类复用两套实例 |
| **前置** | 项目 1 |
| **选做** | `pulumi convert --from terraform` 把 labs/02 的 TF 模块转成 TS 初稿，对比生成代码与手写组件的差距 |
| **验收标准** | 组件实例化两套服务后改组件一处两实例同步更新；`pulumi stack --show-urns` 资源呈父子树结构（put into README 截图或文本） |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「ComponentResource」。请给我完整 TypeScript 代码约 150 行：web-service 组件类（容器+网络+端口输出），同程序实例化两套服务，附 pulumi stack --show-urns 验证父子关系。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 6：给 IaC 写测试——Mocks 单测 + Policy 拦截

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~130 行（测试 + 策略） |
| **核心知识点** | `pulumi.runtime.setMocks` 单测（mocha，`npm test`）、断言资源属性、CrossGuard Policy Pack 拦截违规（如镜像禁用 latest、资源必须带标签） |
| **前置** | 项目 1 |
| **验收标准** | `npm test` 全绿且断言了资源属性（非空跑）；故意写违规配置在 `pulumi preview --policy-pack` 下被拦截（红） |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「IaC 测试」。请给我完整 TypeScript 代码约 130 行：pulumi.runtime.setMocks 的 mocha 单测（断言资源属性）+ CrossGuard policy pack（拦截 latest 镜像与缺标签），附 npm test 与 policy 拦截演示命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 7：Python 对照——同题重写

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~100 行 Python |
| **核心知识点** | Python SDK（venv + pip 清华源装 pulumi/pulumi-docker）、Output 与 args 字典的写法差异、同一引擎多语言、两栈并存互操作 |
| **前置** | 项目 1（拿 TS 版成品逐行对照） |
| **验收标准** | Python 版与 TS 版部署等价资源：`pulumi stack export` 资源清单逐项对比一致；两 stack 并存且互不干扰 |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「Python 对照」。请给我完整 Python 代码约 100 行（venv + pip 装 pulumi/pulumi-docker）：与 TS 版同题（nginx 容器+网络），演示 Python SDK 的 args/Output 写法，附与 TS 版逐步对照说明。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 8：Output 编程模型深水区——apply 陷阱与依赖图

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 TypeScript |
| **核心知识点** | `Output<T>` 异步边界、apply 组合与嵌套陷阱（拿不到原始值）、`pulumi.all` 聚合、显式 dependsOn 与隐式依赖推断、`pulumi stack graph` 导出依赖图、`--parallel` 并行度 |
| **前置** | 项目 1、2 |
| **⚠️ 风险** | TS 主线最大坑区（Output 不能当普通值用），建议放慢做、把每个陷阱写成可复现的最小例子 |
| **验收标准** | 依赖图导出与代码注解一一对应（贴进 README）；`--parallel 1` 与默认并行两次 `up` 结果一致（幂等验证） |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「Output 深水区」。请给我完整 TypeScript 代码约 120 行：演示 Output<T> 的 apply 组合、错误的嵌套 apply 最小复现、pulumi.all 聚合、显式 dependsOn 与隐式依赖，附 pulumi stack graph 导出与 --parallel 对照实验。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第三阶段：多 Provider——K8s/AWS 与交付闭环（项目 9-12）

> **目标**：跨出 Docker——用同一套程序模型编排 K8s 与 AWS 资源，最后把 preview/up 接进 CI 形成交付闭环

### [ ] 项目 9：Kubernetes Provider——kind 部署应用

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 TypeScript |
| **核心知识点** | Kubernetes provider 配置（kubeconfig/context 指定 kind 集群）、Deployment + Service 声明、镜像 tag 变更触发 rollout、destroy 后命名空间清空 |
| **技术栈** | kind 0.32.0（✅ 已装，集群在跑）+ @pulumi/kubernetes 4.34.2 |
| **⚠️ 风险** | 开工前 `kind create cluster --name pulumi-lab` 建专用集群（避免污染现有 kind 集群），provider 插件首装已实测可从 get.pulumi.com 直连下载 |
| **验收标准** | `pulumi up` 后 `kubectl get deploy,svc` 可见资源；改镜像 tag 再 up 触发 rollout（`kubectl rollout status` 通过）；`pulumi destroy` 后 `kubectl get all` 零残留 |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「Kubernetes Provider」。请给我完整 TypeScript 代码约 150 行（@pulumi/kubernetes）：连接 kind 集群（专用 context），声明 Deployment+Service（nginx），演示改镜像 tag 触发 rollout 与 destroy 清空。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 10：AWS Provider——LocalStack 上管云资源

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 TypeScript |
| **核心知识点** | AWS provider 配置（endpoint 指向 http://localhost:4566、假凭证、skipCredentialsValidation）、S3 bucket + 对象声明、与 awslocal 交叉验证、provider 插件下载 |
| **技术栈** | LocalStack 2026.8.0（✅ 已装）+ @pulumi/aws 7.50.0（插件包 darwin-arm64 已实测 200 可下） |
| **⚠️ 风险** | LocalStack 2026-03 起需免费账号 token（本机 hands-on-aws 已配好，开工 `localstack start -d` 探活）；个别服务有能力边界（参考 hands-on-aws 速查表），S3 为首选最稳服务 |
| **验收标准** | `pulumi up` 建出 bucket；`awslocal s3 ls` 可见且能 `aws s3 cp` 对象进去；`pulumi destroy` 后 bucket 消失 |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「AWS on LocalStack」。请给我完整 TypeScript 代码约 150 行（@pulumi/aws）：provider 配置指向 http://localhost:4566（skipCredentialsValidation、假凭证），建 S3 bucket + 上传对象，附 awslocal 交叉验证命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 11：⛓️ 多 Provider 混合编排——一次跨三栈

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 TypeScript |
| **核心知识点** | 同程序混用 docker + kubernetes + aws 三 provider、跨 provider 的 Output 流动（LocalStack S3 上的内容流向 K8s ConfigMap）、dependsOn 显式编排执行顺序、单栈管理三世界资源 |
| **前置** | 项目 9、10 |
| **验收标准** | 一次 `pulumi up` 跨三 provider 建成且顺序正确（S3 先于 ConfigMap）；`pulumi destroy` 后三 provider 资源全清；`pulumi stack` 同栈可见三类资源 |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「多 Provider 混合编排」。请给我完整 TypeScript 代码约 200 行：同程序混用 docker + kubernetes + aws（LocalStack），LocalStack S3 的内容流向 K8s ConfigMap，用 dependsOn 保证顺序，一次 up 全建成。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 12：🏁 交付闭环——preview 门禁进 CI

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（workflow + 脚本） |
| **核心知识点** | `pulumi preview --diff` 作 PR 门禁、`pulumi up --yes` 部署、`--expect-no-changes` 漂移门禁、CI 内凭证注入（假凭证 + LocalStack 端点）、复用 cicd/01 的 act 本地回路 |
| **前置** | 项目 4（state 后端）、项目 9 或 10 |
| **验收标准** | act 本地跑通 preview → up 链路（真仓库推送选做）；故意改资源后 preview `--diff` 显示变更条目；无变更时 `pulumi up --expect-no-changes` 退出码 0 |

**🤖 开始提示词**：
> `我要开始 Pulumi 项目「交付闭环」。请给我约 150 行：GitHub Actions workflow（可用本仓库 cicd/01 的 act 本地跑）执行 pulumi preview --diff 门禁 + pulumi up --yes + --expect-no-changes 漂移检查，含 secret 注入方式。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 📅 周计划

| 周次 | 内容 | 项目数 |
|:---|:---|:---:|
| **第 1 周** | 项目 1-3（CLI 回路 / 编程语言对照 / Stack 与配置） | 3 |
| **第 2 周** | 项目 4-6（状态迁移 / 组件封装 / 测试与策略） | 3 |
| **第 3 周** | 项目 7-9（Python 对照 / Output 深水区 / K8s） | 3 |
| **第 4 周** | 项目 10-12（AWS / 混合编排 / CI 闭环） | 3 |

## 🏆 里程碑

- [ ] **完成项目 1-4** → 「Pulumi 操作手」：CLI 回路、stack/state 全掌握，与 Terraform 逐条对照无障碍
- [ ] **完成项目 5-8** → 「组件工程师」：组件化 / 测试 / 跨语言 / Output 模型无盲区
- [ ] **完成项目 9-12** → 「多云编排者」：三 provider 混合交付 + preview 门禁 CI 闭环

## 📝 每日日志

| 日期 | 项目 | 耗时 | 收获 | 踩坑 |
|:---|:---|:---:|:---|:---|
| | | | | |

## 🔧 环境配置

```bash
# 0. 已就绪（✅ 2026-10-15 实测）
#    docker 29.8.2（运行中）、node v22.23.2（npm registry=npmmirror）
#    python 3.10.20（pip=清华源）、kind 0.32.0（集群在跑）、terraform（对照阅读用）
#    localstack CLI 2026.8.0（已装，装机历史见 hands-on-aws 仓库）
#    get.pulumi.com 插件源直连可达（docker/kubernetes/aws 插件包 HEAD 200 实测）
#    npmmirror 含全部 @pulumi/* SDK：pulumi 3.268.0 / docker 5.2.0 / kubernetes 4.34.2 / aws 7.50.0 / policy 1.21.0

# 1. 需安装（项目 1 之前）
brew install pulumi                     # brew 已收录 3.268.0

# 2. 按阶段用到时装
#    项目 7（Python 对照）：
python3 -m venv .venv && source .venv/bin/activate && pip install pulumi pulumi-docker
#    项目 4（state 后端）：复用 labs/03 的 docker 起 MinIO 方式，无需新装
#    项目 9：kind create cluster --name pulumi-lab
#    项目 10：localstack start -d && localstack status   # 需免费账号 token（本机已配）

# 3. 每项目开工前
docker info --format '{{.ServerVersion}}'   # docker 活着
pulumi version                              # CLI 可用
kind get clusters                           # 项目 9/11：pulumi-lab 存在
```

## ⚠️ 与已有清单的关系

| 已有清单 | 关系 |
|:---|:---|
| **devops.md 项目 1-5**（Terraform IaC 深水区，已完成） | 同域对照不重复：本清单项目 1/3/4/5 是 TF 同题（容器/多环境/状态/模块）的 Pulumi 版——TF 概念不重讲，两栏并读建立「声明式 DSL vs 通用语言」心智映射 |
| **devops.md 项目 21**（Flux GitOps，已完成） | 项目 9 用 Pulumi K8s provider 做 push 式部署，与 Flux 的 pull 式收敛互补对照；Flux 本体不重做 |
| **devops.md 项目 22**（OPA/Conftest，已完成） | 项目 6 的 CrossGuard 是引擎内置策略方案，与 OPA 外挂式对照；OPA 不重做 |
| **devops.md 项目 24**（SOPS 密钥，已完成） | 项目 3 覆盖 Pulumi 内置 secrets（state 内加密）；与 SOPS 的「文件加密」边界写进项目 3 笔记 |
| **devops.md 项目 28**（漂移检测，已完成） | 项目 4 的 `pulumi refresh` 为漂移检出工具链新增一员，与 lab 28 的 TF/Ansible 漂移方案并列 |
| **cicd 项目 1**（act 本地回路，已完成） | 项目 12 直接复用 act 跑 preview 门禁；workflow 语法不再教学 |
| **hands-on-aws**（LocalStack 30 实验） | 项目 10/11 复用其已验证的 LocalStack 环境；只学「用 Pulumi 描述 AWS」，不重学 AWS 服务本身 |
| **跳过项** | Pulumi Cloud 托管控制台 / ESC / Automation API / `pulumi convert` 深潜 / Go SDK——「快速上手」定位不含，需要时另开进阶线 |

## 📚 能力实测速查表

| 能力 | 涉及项目 | 实测结论 |
|:---|:---|:---|
| Docker 引擎 | 全部 | ✅ 29.8.2 运行中（2026-10-15） |
| Pulumi CLI | 全部 | ✅ 3.268.0 已装（brew，2026-10-15）；实验 01 全流程验证 |
| get.pulumi.com 插件源 | 全部 | ✅ 直连可达（docker/kubernetes/aws 插件包 HEAD 200）；docker provider 插件实测自动下载安装成功（实验 01） |
| npmmirror @pulumi/* SDK | 1-6、8-12 | ✅ pulumi 3.268.0 / docker 5.2.0 / kubernetes 4.34.2 / aws 7.50.0 均可查 |
| Node 22 运行时 | 全部 TS 项目 | ✅ v22.23.2；tsc --noEmit 编译期拦截实测通过（实验 02） |
| Python + pip 清华源 | 7 | ✅ 3.10.20；venv + pulumi 包装配首跑验证 |
| kind | 9、11 | ✅ 0.32.0，集群在跑；开工建专用集群 `pulumi-lab` 探活 |
| LocalStack | 10、11 | ⚠️ CLI 2026.8.0 已装但当前 stopped；hands-on-aws 30 实验已验证；2026-03 起需免费 token |
| MinIO 当 S3 后端 | 4 | ✅ labs/03（TF）与 pulumi/04（Pulumi s3 backend）双真机验证（2026-10-15）；建桶 mc 镜像优先、宿主 aws CLI 兜底 |
| CrossGuard Policy Pack | 6 | ⚠️ 首跑验证（CrossGuard 随 CLI 分发，无需单独装插件） |
| act 本地 CI | 12 | ✅ cicd/01 真机验证（act 0.2.89 离线回路） |
| aws provider 插件体积 | 10、11 | ⚠️ 包较大首次下载慢；建议 `pulumi plugin install resource aws` 预装 |

## 📚 来源

- [Pulumi 官方文档](https://www.pulumi.com/docs/)
- [Pulumi Docker Provider](https://www.pulumi.com/registry/packages/docker/)
- [Pulumi Kubernetes Provider](https://www.pulumi.com/registry/packages/kubernetes/)
- [Pulumi AWS Provider（配合 LocalStack）](https://www.pulumi.com/registry/packages/aws/)
- [Pulumi 自建 S3 State 后端](https://www.pulumi.com/docs/iac/concepts/state-and-backends/)
- [CrossGuard 策略即代码](https://www.pulumi.com/docs/iac/crossguard/)

> 动手实验统一放 `pulumi/NN_short_name/`，编号与本清单项目号 1:1 对应；结构沿用 devops 主线 labs/ 约定（README 教程 + 主脚本 + 声明式配置）。
