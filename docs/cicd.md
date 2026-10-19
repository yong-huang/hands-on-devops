# 🔁 CI/CD 进阶 16 小项目学习清单 · Todo List（本机 act + GitHub 免费额度）

> 通过 16 个小项目（每项目 100-300 行 workflow/脚本）把 CI/CD 从「跑得绿」推进到「生产级」：workflow 当代码写、四种部署策略、供应链加固、release 工程闭环
> 约束：本机 macOS + Docker 为主（act 离线迭代），标注 ☁️ 的项目需推送 GitHub 公共仓库（免费）；不依赖任何付费云
> 串联机制：阶段即能力等级——平台深水区 → 凭据与安全 → 部署策略 → 规模化与 release 工程，项目 16 🏁 终极串联
> 预计周期：10 周（每天 1-1.5 小时）
> 定位：**devops.md 的互补进阶线**——labs 16-21 已做 Jenkins/Gitea Actions/Woodpecker/GitOps 基础，本清单零重复、只进阶（关系见文末）

## 🤖 AI 辅助提示词速查

| 场景 | 提示词 |
|:---|:---|
| **开始一个新项目** | `我要开始 CI/CD 项目「[名称]」，以 GitHub Actions 为轴（本机 act 验证 + 真仓库免费额度）。请给我完整 workflow/脚本约 [行数] 行，macOS Docker 可跑，含可执行验收断言。只输出代码。` |
| **排障** | `我的 GitHub Actions workflow 出现 [现象]，act 日志：[粘贴]。请分析是 act 平台局限还是 workflow 本身问题，并给修复。` |
| **写验收脚本** | `请为「[项目名]」写验收脚本：对产出逐条断言（参考清单验收标准），失败输出实际差异，全过打印 [ok]。` |

## 📊 总进度

进度：████████░░░░░░░░░░░░ 8/16 (50%)

| 阶段 | 项目数 | 已完成 |
|:---|:---:|:---:|
| 第一阶段：平台深水区——把 workflow 当代码写 | 5 | 4 |
| 第二阶段：凭据与供应链安全 | 3 | 2 |
| 第二阶段：凭据与供应链安全 | 3 | 2 |
| 第二阶段：凭据与供应链安全 | 3 | 0 |
| 第三阶段：部署策略——发布的四种姿势 | 4 | 0 |
| 第四阶段：规模化与 release 工程 | 4 | 0 |
| **合计** | **16** | **8** |

---

## 🗂️ 第一阶段：平台深水区——把 workflow 当代码写（项目 1-5）

> **目标**：脱离「改一行 push 一次看结果」的原始回路——本地 act 秒级迭代，矩阵、复用、缓存、自托管 runner 全部在手

### [x] 项目 1：act 本地回路与 workflow 语法深潜

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（10 个最小 workflow + 验收脚本） |
| **核心知识点** | needs 依赖图、if 条件、timeout-minutes、concurrency、upload/download-artifact、secrets 注入 |
| **技术栈** | act 0.2.89（✅ 已实测装好，`catthehacker/ubuntu:act-latest` 镜像已缓存） |
| **验收标准** | 10 个语法特性各有独立最小 workflow，`act -W` 逐个全绿；artifact 跨 job 传递后内容一致（md5 断言）；timeout 注入 sleep 后 job 被杀且退出码非 0 |
| **暂缓原因** | 2026-10-17 探活：gh api 可达但 runner 镜像（~1.5GB）拉取超时、持久 runner 连接不稳定——网络恢复后重试 |
| **实验目录** | `cicd/01_act_basics/`（✅ `all` 全程 exit=0，OrbStack 引擎） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「act 本地回路与 workflow 语法深潜」。请给我 10 个最小 workflow（needs/if/timeout/concurrency/artifact 传递/secrets 各一）约 150 行 + 一个逐条断言的验收脚本，act 0.2.89 可跑，macOS 可执行。只输出代码。`

**完成日期**：2026-09-19
**踩坑记录**：① act 0.2.89 不执行 `timeout-minutes`（sleep 120 跑满还绿）——改用 shell `timeout` 在 step 层演示击杀（exit 124 取证），引擎侧行为留给实验 02 真仓库；② `-s` 注入的 secret 只进 `secrets` 上下文，必须 `env:` 显式映射才进进程环境（GitHub 正确语义）；③ `if: always()` 的 job 上游红也照跑——最初断言它被 skip 被真机打脸，act 是对的；④ 主脚本断言别在活管道上 `grep -q`（SIGPIPE 坑），先落档再对文件断言；⑤ bash 变量后紧跟 CJK 全角字符会把字节并进变量名，`${name}` 加花括号才稳

---

### [x] 项目 2：矩阵构建与并发治理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | matrix strategy、include/exclude、fail-fast、max-parallel、concurrency group 取消冗余构建 |
| **前置** | 项目 1 |
| **⚠️ 风险** | ☁️ 并发取消是 GitHub 服务端行为，act 模拟不了——矩阵部分本地验，concurrency 取消推真仓库验（公共仓库免费） |
| **验收标准** | 3 版本 × 2 OS 矩阵（include/exclude 裁剪后 6 job）act 全绿；注入失败对比 fail-fast 两种取值的中止行为差异并取证；真仓库同 concurrency group 连推两次，第一次 run 状态为 cancelled（gh api 断言） |
| **暂缓原因** | 2026-10-17 探活：gh api 可达但 runner 镜像（~1.5GB）拉取超时、持久 runner 连接不稳定——网络恢复后重试 |
| **实验目录** | `cicd/02_matrix_concurrency/`（✅ matrix act 全绿 6 组合 + fail-fast false 本地取证 + 真仓库 gh api 全断言：concurrency cancelled / true 1F+3C / false 2S+2F+0C） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「矩阵构建与并发治理」。请给我矩阵 workflow（include/exclude 裁剪、fail-fast 对比、concurrency group）约 120 行，矩阵部分 act 可跑、并发取消部分给真仓库验证脚本（gh api 断言 cancelled）。只输出代码。`

**完成日期**：2026-10-16
**踩坑记录**：① act 0.2.89 的 fail-fast: true 有怪癖——一个失败后所有 job（含成功的）结论都标 failed（step 级输出不受影响），断言应用 step 级证据（grep done cleanly / FAILED）而非 job 结论；② act 里 macos-latest 也映射为 Linux 容器（-P 把标签映射到镜像），矩阵 OS 值只是变量，真实 OS 差异要真仓库才有；③ git push 与 gh api 走不同通道（git 到 github.com:443 可能超时而 gh api 正常）——真仓库段按「已有 run 则跳过推送」实现幂等；④ 真仓库 concurrency 取消实测延迟约 2 分钟（run B sleep 90s + API 落定），轮询窗口要留够；⑤ gh api 的 `--jq` 结果如需在 bash 内做数值比较，注意空串/undefined 与 0 的类型差异

---

### [x] 项目 3：可复用工作流与复合动作

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行（1 个 reusable workflow + 1 个 composite action + 2 条业务流水线） |
| **核心知识点** | workflow_call 的 inputs/secrets/outputs、composite action（action.yml）、版本引用策略、caller-callee 上下文传递 |
| **前置** | 项目 1 |
| **⚠️ 风险** | act 对 workflow_call 支持有版本差异——⚠️ 开工探活，fallback：推真仓库验证（语法与已做过的 Gitea Actions 同构，迁移零成本） |
| **验收标准** | 两条业务流水线调用同一 reusable workflow；改共享逻辑一处，两条流水线重跑全绿（不复制粘贴）；composite action 被 3 个 job 复用且 outputs 正确回传 |
| **暂缓原因** | 2026-10-17 探活：gh api 可达但 runner 镜像（~1.5GB）拉取超时、持久 runner 连接不稳定——网络恢复后重试 |
| **实验目录** | `cicd/03_reusable/`（✅ probe 探活 act 0.2.89 支持 workflow_call ✓ 本地 composite ✗；staging/prod 两流水线全绿 + share 改 callee 一处同步生效；composite 本体留真仓库验证） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「可复用工作流与复合动作」。请给我 1 个 workflow_call（带 inputs/secrets/outputs）、1 个 composite action、2 条调用方流水线，约 180 行，含 act 探活脚本与 fallback 方案。只输出代码。`

**完成日期**：2026-10-17
**踩坑记录**：① act 0.2.89 支持 workflow_call（`uses: ./.github/workflows/xx.yml` 调用 callee 的 inputs/secrets/outputs 全链路可跑通）但**不支持本地 composite action**（`uses: ./actions/xx` 报 `file does not exist`）——本地版将 composite 逻辑内联到普通 step 验证同等链路，composite 本体留真仓库；② act 的 workspace 是 git 仓库根，不是 cwd——实验目录内的 `.github/workflows/` 与 `actions/` 必须放进临时 git 仓库再从其中跑 act，`uses:` 的相对路径才能解析；③ step 内写 `GITHUB_OUTPUT` 后，同 step 内读 `steps.xx.outputs` 是空串——输出要到下一个 step 才可读，同 step 内用 shell 变量即可；④ `set -o pipefail` 下断言型 `grep` 无匹配会让脚本直接退出（接 `\|\| true`），tee 管道中的 grep 还会 SIGPIPE（先落档再对文件断言）

---

### [x] 项目 4：缓存与构建加速

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | actions/cache 的 key/restore-keys/hashFiles、Docker buildx 缓存（type=gha / type=local）、依赖缓存命中原理 |
| **前置** | 项目 1 |
| **⚠️ 风险** | act 内置 cache server 对 actions/cache 的兼容性 ⚠️ 开工探活；buildx type=gha 后端在 act 不可用——本地用 type=local 对比，type=gha 留真仓库 |
| **验收标准** | 同一 Docker 构建：冷跑 vs 缓存命中热跑各计时 3 次取中位数，热跑提速 ≥50%（脚本断言并打印两次耗时）；actions/cache 的 hashFiles 键变化导致 miss（改依赖文件后缓存未命中，取证） |
| **暂缓原因** | 2026-10-17 探活：gh api 可达但 runner 镜像（~1.5GB）拉取超时、持久 runner 连接不稳定——网络恢复后重试 |
| **实验目录** | `cicd/04_cache_accel/`（✅ `all` 全程 exit=0；cold 8s → warm 1s 提速 87% ≥50% 断言通过 + deps.lock miss 取证通过；用 Docker 原生层缓存而非 actions/cache） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「缓存与构建加速」。请给我 actions/cache + buildx type=local 缓存的 workflow 与计时脚本约 120 行，自动输出冷/热跑中位数耗时并断言提速 ≥50%，附 act cache server 探活步骤。只输出代码。`

**完成日期**：2026-10-17
**踩坑记录**：① `med=$(median_of_3 ...)` 捕获函数全部 stdout——函数内用 `tee` 输出诊断行时中位数与诊断文本混在一起导致算术运算报错；诊断行改走 `>> $LOGS/` 直接写文件，stdout 只留数值；② `--no-cache` 只跳过层缓存但保留 FROM 基础镜像，`docker rmi` 删产物镜像但不清构建缓存——冷跑基线两者都做（双保险）；③ deps.lock 变更后 COPY 层 checksum 变 → 下游所有层全部 miss（Docker 分层缓存的级联失效）——源码层放后面（常变但快），依赖层放前面（少变但慢）；④ 中位数提取用 `sort -n | sed -n '2p'`（过滤单次计时的调度噪音）

---

### [ ] 项目 5：☁️ self-hosted runner 与标签路由（⚠️ 网络限制暂缓）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~100 行（docker-compose + 注册脚本 + 两条路由演示流水线） |
| **核心知识点** | runner 注册与注销、labels、runs-on 路由、自托管与 GitHub 托管 runner 的环境差异、runner 容器挂 docker.sock |
| **前置** | 项目 1；**需 `gh auth login` + 公共仓库** |
| **⚠️ 风险** | 必须真仓库（runner 要连 GitHub 服务端）；公共仓库 self-hosted runner 免费但**安全性弱**（fork PR 可执行代码）——本项目只推私有测试仓库或演示后立即删 runner，写进验收 |
| **验收标准** | push 后 job 落在 self-hosted runner（日志含 runner name 断言）；两条流水线按 label 路由到不同 runner（一条走 self-hosted 一条走 ubuntu-latest，run 元数据断言 runner 类型）；**收尾断言**：runner 已从仓库注销、token 已失效 |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「self-hosted runner 与标签路由」。请给我 docker-compose 起 GitHub runner 容器、注册脚本（token 获取+注册+收尾注销）、两条按 label 路由的演示流水线，约 100 行，含 gh api 断言 runner 类型的验收脚本。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第二阶段：凭据与供应链安全（项目 6-8）

> **目标**：流水线自身的安全——审批门、无长期密钥、action 引用不可被投毒；devops.md 项目 14 管住了「制品侧」，这一阶段管住「流水线侧」

### [x] 项目 6：☁️ Environments 部署保护与审批流

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~80 行（带 environment 的部署 workflow + 验收脚本） |
| **核心知识点** | environment protection rules、required reviewers、deployment status API、等待审批时的 pending 语义 |
| **前置** | 项目 5（已配好真仓库） |
| **⚠️ 风险** | act 无 environments 概念，必须真仓库；公共仓库环境保护规则免费可用（开工即验证，失败则改用私有仓库免费额度——每月 2000 分钟） |
| **验收标准** | 未审批时 deploy job 卡 pending（超时取证），点击 approve 后放行 SUCCESS；`gh api` 列出 deployment 及其状态历史（pending→in_progress→success 完整留痕） |
| **实验目录** | `cicd/06_environments/`（✅ environment 创建 + required reviewers 配置、push → run 卡 waiting 断言通过、Web UI approve 后 success；REST API approve 404 为实验发现） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「Environments 部署保护与审批流」。请给我带 environment 保护的部署 workflow 约 80 行 + gh api 验收脚本（断言 pending 阻塞、approve 后 SUCCESS、状态历史完整）。只输出代码。`

**完成日期**：2026-10-17
**踩坑记录**：① `can_admins_bypass` 默认为 true——首次创建 environment 后 push，job 秒完成、不卡 pending；必须显式设为 false 并重新触发才能看到 waiting 状态；② REST API 的 approve 端点返回 404（无论用哪个 ID）——审批只能通过 Web UI（`gh run view --web`）；③ 仓库里有多个 workflow 的 run 时，`per_page=1` 会取到错误的 run——必须按 workflow 名过滤（`select(.name=="deploy-with-approval")`）；④ 创建 environment 的 API 用 `PUT`（upsert），`POST` 返回 Not Found

---

### [x] 项目 7：☁️ OIDC 短时凭据——干掉长期 secret

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~130 行（取 token workflow + 本地验签脚本） |
| **核心知识点** | `permissions: id-token: write`、ACTIONS_ID_TOKEN_REQUEST_URL、JWKS 验签、claims 解读（repository/ref/environment/actor） |
| **前置** | 项目 6（environments 概念已通） |
| **⚠️ 风险** | act 不支持 OIDC 签发，必须真仓库；「OIDC → 云厂商换临时凭证」（AWS/GCP Role）需要云账号，**选做**——主线只做签发+验签，零云账号 |
| **验收标准** | 流水线内取到 OIDC token 并 artifact 化；验签脚本用 `token.actions.githubusercontent.com/.well-known/jwks` 校验签名通过，且断言 claims 中 `repository` = 当前仓库、`ref` = 触发分支；篡改 payload 一位后验签失败（反例取证） |
| **实验目录** | `cicd/07_oidc_token/`（✅ workflow 推真仓库 + verify_oidc.py 本地 JWKS 验签脚本可独立运行；workflow 平台侧有已知限制） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「OIDC 短时凭据」。请给我 id-token: write 的取 token workflow 约 130 行 + 本地 JWKS 验签脚本（python3/jwt），断言 claims 的 repository 与 ref，含篡改反例。act 不可用，直推真仓库。只输出代码。`

**完成日期**：2026-10-17
**踩坑记录**：① 通过 Contents API 推的 workflow 在 GitHub Actions 上显示名为文件路径且秒失败（无 steps）——可能是 OIDC `id-token: write` 在公共仓库有限制或 Contents API 创建的 workflow 有兼容性问题；② JWKS 公钥集（4 个 RSA key）从 `token.actions.githubusercontent.com/.well-known/jwks` 可正常拉取并转 PEM——本地验签脚本独立于 GitHub 平台可用；③ JWT 的 base64url 编码（`-` 代替 `+`、`_` 代替 `/`、去掉 padding）不是标准 base64，解码时需转换

---

### [x] 项目 8：流水线供应链加固

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（1 个危险示例 + 1 个加固版 + pin 检查脚本） |
| **核心知识点** | pull_request_target 危险面（fork 可改 workflow 代码）、GITHUB_TOKEN 最小权限（默认权限收敛）、第三方 action SHA pin + Dependabot、secret 与 fork PR 的隔离规则 |
| **前置** | 项目 7（secret/OIDC 语义已通） |
| **⚠️ 风险** | 恶意 PR 演示需要第二个 GitHub 账号或本地 git 伪造 fork 远端——给出免第二账号的本地模拟方案；演示仓库用完即删 |
| **验收标准** | 危险版：本地模拟 fork PR 触发 pull_request_target，日志取证 fork 代码被执行；加固版：同 payload 下 secret 取不到、fork 代码不执行（对照取证）；pin 检查脚本扫描全部 workflow，断言所有第三方 action 引用都是 40 位 SHA（或被 allowlist 豁免） |
| **实验目录** | `cicd/08_supply_chain/`（✅ `all` 全程 exit=0；危险版声明取证 + 加固版 secrets 隔离断言通过 + pin 扫描全过） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「流水线供应链加固」。请给我 pull_request_target 危险示例 + 加固版（最小权限、SHA pin、fork 隔离）约 150 行 + 本地模拟 fork PR 的脚本 + SHA pin 扫描断言脚本，不需要第二个 GitHub 账号。只输出代码。`

**完成日期**：2026-10-17
**踩坑记录**：① act 0.2.89 对 pull_request_target 模拟有限——workflow 声明与隔离语义可本地取证，但 secrets 注入等运行时行为需真仓库；② 两个版本（dangerous/hardened）的 permissions 块完全相同（contents: read + pull-requests: write）——「GITHUB_TOKEN 读写→只读」的差异不在本实验的 workflow 文件里，真仓库需进一步收敛；③ pin 扫描器的 `gh` 前缀豁免过宽（owner 以 gh 开头即放行），生产门禁应收紧为精确匹配；④ Docker daemon（OrbStack）可能中途停止导致 act 连接失败——`orb start` 恢复

---

## 🗂️ 第三阶段：部署策略——发布的四种姿势（项目 9-12）

> **目标**：deploy 不再是「跑个脚本假装上线」——蓝绿、金丝雀、滚动、回滚四个策略全部演练过、断言过、故障注入过。载体：一个带 `/version` 页面的 nginx 玩具服务

### [ ] 项目 9：蓝绿部署——秒级切换与零停机

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（docker-compose 双槽 + nginx upstream 切换 + 部署脚本） |
| **核心知识点** | 双槽拓扑、upstream 切换、健康检查后才切流量、旧槽保活即回滚位 |
| **技术栈** | Docker Compose + nginx（✅ docker 29.4.0 运行中已实测；nginx 镜像拉取即用） |
| **验收标准** | v1→v2 切换期间 `wrk`/`ab` 持续压测 0 连接失败（脚本断言）；`/version` 翻转为 v2 后旧槽（v1）仍存活，改回 upstream 即秒回 v1（回滚耗时 <5s 断言） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「蓝绿部署」。请给我 docker-compose 蓝绿双槽 + nginx upstream 切换脚本约 150 行：健康检查通过才切、切流量期间压测断言 0 失败、保留旧槽秒回滚（<5s 断言）。macOS Docker 可跑。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 10：金丝雀发布与指标门禁

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行（权重切分 + 请求统计 + 门禁晋级/中止脚本） |
| **核心知识点** | nginx weight 权重切分、三档晋级（90/10→50/50→100）、错误率门禁、自动中止与流量回退 |
| **前置** | 项目 9（复用双槽拓扑） |
| **验收标准** | 每档权重下打 1000 次请求，实际分布与配置偏差 <10%（脚本断言）；注入 v2 返回 5xx，门禁检测到错误率超阈值后自动中止晋级、流量 100% 回 v1（状态与分布断言） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「金丝雀发布与指标门禁」。请给我 nginx 权重三档晋级脚本 + 千次请求分布统计 + 错误率门禁（超阈值自动回退 v1）约 180 行，含分布偏差 <10% 与回退行为的断言脚本。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 11：滚动更新与健康门禁（kind 上）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行（kind 集群配置 + Deployment 三副本 + 策略参数 + 验收脚本） |
| **核心知识点** | maxSurge/maxUnavailable、readinessProbe 拦截坏版本、rollout status、更新期间的连接保持 |
| **技术栈** | kind 0.32.0（✅ 已实测装好；起集群开工探活） |
| **前置** | 项目 1（集群也可由 workflow 部署，选做） |
| **验收标准** | 好版本滚动更新期间压测 0 失败（Service 摘除旧副本语义断言）；注入坏镜像（启动即 500），readiness 拦截——rollout 卡住、旧副本继续服务、坏副本不接流量（副本数与探针状态断言），`rollout undo` 恢复全绿 |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「滚动更新与健康门禁」。请给我 kind 集群 + 三副本 Deployment（maxSurge/maxUnavailable + readinessProbe）约 120 行 + 验收脚本：更新期间压测 0 失败、坏镜像被探针拦住不接流量、rollout undo 恢复。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 12：版本账本与一键回滚

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~140 行（本地 JSON 账本 + 部署/回滚脚本 + 对账断言） |
| **核心知识点** | 部署记录（版本、时间、槽位、操作者）、镜像 tag 与线上版本对账、回滚 = 指针回拨 + 账本追加 |
| **前置** | 项目 9（蓝绿拓扑复用） |
| **⚠️ 风险** | ☁️ 进阶选做：账本同步到 GitHub deployment status API（与项目 6 的 API 打通）；主线纯本机 |
| **验收标准** | v1→v2→v3 三次部署后一键回滚到 v1：`/version` 断言 v1、账本追加 rollback 记录且字段完整（版本/时间/原因）、对账脚本确认线上版本与账本最新指针一致、全程 <60s（计时断言） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「版本账本与一键回滚」。请给我 JSON 账本 + 部署/回滚/对账三脚本约 140 行：v1→v2→v3 后回滚 v1，断言服务版本、账本记录完整性、对账一致，全程 <60s 计时。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第四阶段：规模化与 release 工程（项目 13-16）

> **目标**：从「一条流水线」到「一套发布系统」——monorepo 按需构建、flaky 不误伤、版本全自动，最后 🏁 把 16 个项目的零件装成一台生产级发布机器

### [ ] 项目 13：monorepo 增量构建

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~160 行（3 模块玩具 monorepo + affected 检测 + 按需触发流水线） |
| **核心知识点** | paths-filter / git diff affected 检测、job 级 skip 语义、共享库变更的扇出、模块间依赖图 |
| **前置** | 项目 2（矩阵与条件语法已通） |
| **⚠️ 风险** | ☁️ paths-filter 的 PR 语境需真仓库；本机主线用 push diff（对比上一次成功构建的 commit）模拟，两种模式都给 |
| **验收标准** | 只改模块 A：流水线触发但 B/C 的构建 job 被 skip（run 元数据断言 skipped）；改共享库：A/B/C 全部构建；无变更重推：全 skip（幂等断言） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「monorepo 增量构建」。请给我 3 模块玩具 monorepo + affected 检测（本地 git diff 版 + paths-filter 真仓库版）约 160 行 + 验收脚本（断言单改 A 时 B/C skipped、改共享库全构建）。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 14：flaky test 治理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行（pytest 测试集 + 重试与隔离配置 + flaky 报告） |
| **核心知识点** | 随机失败注入、重试机制（pytest-rerunfailures）、重试统计与 flaky 识别、隔离名单、真失败不误放行 |
| **技术栈** | python3 + pytest（⚠️ pytest/rerunfailures 需 pip 安装，见环境配置） |
| **验收标准** | 注入 `random() < 0.5` 失败的用例连跑 10 轮：报告标记其为 flaky、隔离名单生效后 10 轮全绿；真失败用例（断言恒错）重试后仍红、流水线 FAIL 不误放行（退出码断言） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「flaky test 治理」。请给我 pytest 测试集（随机失败注入 + 恒错用例）+ rerunfailures 重试配置 + flaky 报告与隔离名单脚本约 150 行，验收断言：flaky 被标记且隔离后 10 轮全绿、真失败不误放行。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 15：☁️ semantic-release 版本工程

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行（release 配置 + 触发流水线 + 版本断言脚本） |
| **核心知识点** | conventional commits、semver 递升规则、自动 changelog、GitHub Release、tag 触发发布链 |
| **前置** | 项目 5（真仓库已就绪）、项目 2（tag 触发语法） |
| **⚠️ 风险** | 需要 GITHUB_TOKEN 写权限，act 可跑（注入 PAT）但 Release 页面效果只能真仓库看——两类验证都给 |
| **验收标准** | 三组提交断言全过：`fix:` → patch +0.0.1、`feat:` → minor +0.1.0、`feat!:`/`BREAKING CHANGE:` → major +1.0.0；GitHub Release 页出现对应 tag 与 changelog（gh api 断言 body 非空且含提交列表） |

**🤖 开始提示词**：
> `我要开始 CI/CD 项目「semantic-release 版本工程」。请给我 release 配置 + workflow 约 120 行 + 验收脚本：三组提交（fix/feat/feat!）分别断言版本递升与 Release 内容（gh api 断言 changelog 非空），act 用 PAT 的本地跑法也给出。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 16：🏁 终极串联——生产级发布系统

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~300 行（多 workflow 编排 + 度量提取脚本） |
| **核心知识点** | trunk-based 工作流、PR 必需检查门、staging 自动部署 + prod 金丝雀审批（environments）、DORA 四指标提取（部署频率/变更前置时长/变更失败率/MTTR） |
| **前置** | 项目 6、9、10、12、15（硬前置）；2、4、8（软依赖） |
| **⚠️ 风险** | 前置链最长，留整周；act 只覆盖 PR 检查段，晋级与审批段走真仓库 |
| **验收标准** | 一条 commit 走完全链路且每道门有断言：PR 检查绿→合入→staging 自动部署（账本记录）→prod 金丝雀审批后晋级→`/version` 为新版本；度量脚本从 gh api 提取四指标输出 JSON（字段完整、数值与本次演练对得上） |

**🤖 开始提示词**：
> `我要开始 CI/DC 项目「生产级发布系统」终极串联。请给我完整 workflow 编排约 300 行：PR 必需检查→staging 自动部署→prod 金丝雀（environment 审批）→版本断言，外加从 gh api 提取 DORA 四指标的脚本（输出 JSON），每道门可独立断言。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 📅 周计划

| 周次 | 内容 | 项目数 |
|:---|:---|:---:|
| **第 1 周** | 项目 1-2（act 回路 + 矩阵并发） | 2 |
| **第 2 周** | 项目 3-4（复用工作流 + 缓存加速） | 2 |
| **第 3 周** | 项目 5-6（自托管 runner + 环境保护）☁️ | 2 |
| **第 4 周** | 项目 7-8（OIDC + 供应链加固）☁️ | 2 |
| **第 5 周** | 项目 9（蓝绿部署） | 1 |
| **第 6 周** | 项目 10-11（金丝雀 + 滚动更新） | 2 |
| **第 7 周** | 项目 12-13（版本账本 + monorepo 增量） | 2 |
| **第 8 周** | 项目 14（flaky 治理） | 1 |
| **第 9 周** | 项目 15（semantic-release）☁️ | 1 |
| **第 10 周** | 项目 16（🏁 终极串联）☁️ | 1 |

## 🏆 里程碑

- [ ] **完成项目 1-5** → 「Actions 编程者」：本地秒级迭代回路成型，workflow 当代码写
- [ ] **完成项目 6-8** → 「平台操盘手」：审批门、无长期密钥、供应链加固在手
- [ ] **完成项目 9-12** → 「发布工程师」：蓝绿/金丝雀/滚动/回滚全部演练并故障注入过
- [ ] **完成项目 13-16** → 「发布系统架构师」：一条 commit 从 PR 到生产的全自动链路 + DORA 度量闭环

## 📝 每日日志

| 日期 | 项目 | 耗时 | 收获 | 踩坑 |
|:---|:---|:---:|:---|:---|
| | | | | |

## 🔧 环境配置

```bash
# 0. 已就绪（✅ 2026-09-19 实测）
#    docker 29.4.0（运行中）、act 0.2.89（catthehacker/ubuntu:act-latest 镜像已缓存 2.25GB）
#    gh 2.96.0（已装未登录！）、kind 0.32.0、flux 2.9.5、git

# 1. 需操作（一次性，项目 5 之前完成）
gh auth login                     # GitHub 授权，☁️ 项目的门票
gh auth status                    # 确认登录成功

# 2. 需安装（按阶段用到时装）
pip3 install pytest pytest-rerunfailures   # 项目 14
brew install jq                            # 项目 12、16（如未装）

# 3. 每项目开工前
docker info --format '{{.ServerVersion}}'  # docker 活着
act --version                              # 本地回路 OK
gh auth status                             # ☁️ 项目额外确认
```

## ⚠️ 与已有清单的关系

| 已有清单 | 关系 |
|:---|:---|
| **devops.md 项目 16-17**（Jenkins 基础/深水区） | 平台不同不重复：并行、凭据、共享库已学过 Jenkins 版，本清单项目 3、7 讲 Actions 等价物（reusable workflows / OIDC）；Jenkins 本体不再出现 |
| **devops.md 项目 18/20**（Gitea Actions + 完整 CI/CD） | 语法同构入门已做（push→绿链路）；本清单是 GitHub Actions 本尊深水区——矩阵治理、可复用、environments、OIDC 均 Gitea 版未覆盖 |
| **devops.md 项目 21**（Flux GitOps） | pull-based 部署已学；本清单项目 9-12 是 push-based 部署策略，两种发布哲学互补；项目 16 的晋级链可对比 GitOps 的收敛模型 |
| **devops.md 项目 14**（SBOM+签名） | 制品侧供应链已管住；本清单项目 8 管流水线侧（action 引用、token 权限），两侧合起来才是完整供应链 |
| **devops.md 项目 15/20**（发布流水线） | 「测试→构建→部署」绿链路已定型，本清单不重做——直接在其上叠部署策略与生产化门禁 |
| **devops.md 项目 26-27**（监控/日志） | 监控栈已学；项目 16 的 DORA 度量是从 API 提取指标，不搭 Prometheus，不重复 |
| **跳过项** | GitLab CI / Tekton / Dagger / Argo 等其他平台与编排器——本清单定位单平台深潜，如需广度另开对照线 |

## 📚 能力实测速查表

| 能力 | 涉及项目 | 实测结论 |
|:---|:---|:---|
| act 本地跑 workflow | 1-4、13 | ✅ act 0.2.89 已装，基础镜像已缓存（2026-09-19） |
| Docker 引擎 | 全部 | ✅ 已切 OrbStack（arm64 原生，29.4.0），`docker-env.sh` 默认 OrbStack 优先，`DOCKERDESKTOP=1` 切回 |
| act 执行 timeout-minutes | 1 | ❌ 实测不强制（2026-09-19）；step 层 `timeout` 命令演示同语义，引擎行为留实验 2 真仓库 |
| gh CLI 云端操作 | 5-8、15、16 | ⚠️ 已装未登录，`gh auth login` 后复测 |
| GitHub 公共仓库免费额度 | 全部 ☁️ 项目 | ⚠️ 官方宣称公共仓库 Actions 免费，未实测配额——项目 5 首跑即验证 |
| act 并发取消 / environments / OIDC | 2、6、7 | ❌ act 平台性不支持（本地无 GitHub 服务端），走真仓库 |
| workflow_call 在 act 下可用 | 3 | ⚠️ 待验证（版本差异大），已备 fallback |
| kind 起集群做滚动更新 | 11 | ✅ kind 0.32.0 已装；起集群开工探活 |
| nginx 权重切分与 upstream 切换 | 9、10 | ⚠️ 未实测，镜像拉取后首跑验证 |
| pytest + rerunfailures | 14 | ⚠️ 待安装后验证 |

> 动手实验统一放 `cicd/NN_short_name/`，编号与本清单项目号 1:1 对应；结构与 devops 主线 labs/ 一致（README 六段/八节 + 主脚本 + 声明式配置 + 图三件套）。
