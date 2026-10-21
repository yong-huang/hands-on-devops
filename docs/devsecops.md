# 🛡️ DevSecOps 安全纵深 30 小项目学习清单 · Todo List（本机零云攻防靶场）

> 通过 30 个小项目（每项目 100-300 行代码/配置）把安全装进开发全生命周期：安全左移 → 流水线门禁 → 容器/K8s 加固 → 运行时检测 → 攻防验证 → 度量治理
> 约束：本机 macOS + OrbStack(Docker) 全跑通、**零云依赖**、全部免费；唯一 SUT 是自建 Python FastAPI 漏洞靶场 vuln-api
> 串联机制：阶段即安全能力等级——左移地基 → 门禁 → 云原生加固 → 运行时检测 → 攻防验证 → 治理交付；项目 6/11 ⛓️ 集成点，项目 30 🏁 终极串联
> 预计周期：12 周（每天 1-2 小时）
> 定位：**devops.md 的安全纵深互补线**——labs 22-25 做过策略/IaC 扫描/密钥/合规的门禁入门，本清单只进阶不重复（关系见文末）

## 🤖 AI 辅助提示词速查

| 场景 | 提示词 |
|:---|:---|
| **开始一个新项目** | `我要开始 DevSecOps 项目「[名称]」，目标是 [目标]。请给我完整代码约 [行数] 行（Python/FastAPI/YAML），macOS + OrbStack 本机可跑、零云，含可执行验收断言。只输出代码。` |
| **排障** | `我的 [工具/靶场] 出现 [现象]，报错/日志：[粘贴]。请分析根因并给修复后的完整代码。` |
| **写验收脚本** | `请为「[项目名]」写验收脚本：对产出逐条断言（参考清单验收标准），失败输出实际差异，全过打印 [ok]。` |
| **红队复审** | `用攻击者视角审查这段代码/配置：[粘贴]。列出可利用点、利用步骤、修复建议，按严重度排序。` |

## 📊 总进度

进度：░░░░░░░░░░░░░░░░░░░░ 0/30 (0%)

| 阶段 | 项目数 | 已完成 |
|:---|:---:|:---:|
| 第一阶段：安全左移·地基 | 6 | 0 |
| 第二阶段：流水线安全门禁 | 5 | 0 |
| 第三阶段：云原生加固 | 6 | 0 |
| 第四阶段：运行时检测与响应 | 5 | 0 |
| 第五阶段：攻防验证 | 4 | 0 |
| 第六阶段：治理与交付 | 4 | 0 |
| **合计** | **30** | **0** |

---

## 🗂️ 第一阶段：安全左移·地基（项目 1-6）

> **目标**：风险在写代码时就被看见——密钥与漏洞进不了仓库

### [ ] 项目 1：Python 漏洞靶场 vuln-api 搭建

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~300 行 |
| **核心知识点** | FastAPI、SQLite、OWASP Top 10 落地形态、漏洞分类学、SUT 设计 |
| **产出模块** | `vuln-api/`（后续 29 个项目共用靶场） |
| **技术栈** | Python 3.13 + FastAPI（已实测本机可跑） |
| **验收标准** | `uvicorn` 起服务后 8 类漏洞端点（SQLi/反射 XSS/SSRF/pickle 反序列化/硬编码密钥/弱 JWT/路径穿越/IDOR）各有一条 PoC curl 返回攻击成功证据；`pytest` 冒烟全过 |
|  | 每个漏洞端点在 README 里有「漏洞说明 + 触发请求 + 预期响应」三段式表格 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「Python 漏洞靶场 vuln-api 搭建」。请给我完整 FastAPI+SQLite 代码约 300 行：故意实现 SQLi、反射 XSS、SSRF、pickle 反序列化、硬编码密钥、弱 JWT（none 算法/弱 secret）、路径穿越、IDOR 共 8 类漏洞端点，每个端点带清晰注释标注漏洞类型，附 PoC curl 清单与 pytest 冒烟测试。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 2：密钥泄漏检测与 git 历史治理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | gitleaks 规则语法、git 全历史扫描、allowlist 治理、git-filter-repo 历史清除 |
| **技术栈** | gitleaks（brew 安装）+ git-filter-repo |
| **前置** | 项目 1 |
| **验收标准** | 往靶场 git 历史塞 8 种格式的假密钥（AWS/AK-SK、私钥、数据库连接串等）后 `gitleaks detect` 检出 ≥8/8 |
|  | `git filter-repo` 清除后重扫报告 0 泄漏，且 `git log` 中原提交不可达 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「密钥泄漏检测与 git 历史治理」。请给我完整脚本与配置约 150 行：gitleaks 自定义规则（内部 API key 格式）、allowlist 配置、8 种假密钥的注入脚本、git filter-repo 清除历史并验证的全流程脚本，macOS 本机可跑，附逐条验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 3：SAST 规则工程（semgrep 自定义规则）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | semgrep 规则语法（pattern/metavariable）、误报治理、inline 抑制审计 |
| **技术栈** | semgrep（pip 安装，macOS arm64 原生支持） |
| **前置** | 项目 1 |
| **验收标准** | 对靶场全量扫描检出 ≥7/8 类漏洞（SSRF 类可豁免说明原因） |
|  | 自写 3 条规则（`pickle.loads`、`verify=False`、字符串拼接 SQL）各自命中至少一处靶场代码，`# nosemgrep` 抑制的位置全部带原因注释且能在报告中列出 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「SAST 规则工程」。请给我完整内容约 150 行：semgrep 自定义规则包 3 条（pickle.loads 反序列化、requests verify=False、f-string 拼接 SQL），对 FastAPI 靶场全量扫描的配置，误报 inline 抑制与审计清单的生成脚本，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 4：SCA 依赖漏洞治理

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | pip-audit / osv-scanner 双引擎、传递依赖、CVE→修复版本决策、升级复检闭环 |
| **技术栈** | pip-audit + osv-scanner（brew 安装） |
| **前置** | 项目 1 |
| **验收标准** | 在 requirements 中故意锁定 2 个含已知 CVE 的旧版本（如 `ecdsa<0.19`、`jinja2<3.1.4`），双引擎检出 2/2 且报告的 CVE 编号一致 |
|  | 升级修复后复检：0 已知高危，且 `pip-audit` 退出码为 0 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「SCA 依赖漏洞治理」。请给我完整脚本约 120 行：requirements 故意锁定 2 个含 CVE 旧版本的漏洞清单、pip-audit 与 osv-scanner 双引擎扫描对比脚本（输出 CVE 编号/严重度/修复版本对照表）、升级修复与复检闭环脚本，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 5：Python 供应链加固（哈希锁定与离线 wheelhouse）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | pip `--require-hashes`、wheelhouse 离线仓库、传递依赖哈希锁定、篡改拒装 |
| **技术栈** | pip（hash-checking mode） |
| **前置** | 项目 4 |
| **验收标准** | `pip download` 生成 wheelhouse 后按哈希锁定安装成功；手动改一个哈希字符再装，pip 拒绝且退出码非 0 |
|  | 离线验证：断网（`--index-url file://`）环境下 wheelhouse 安装全量依赖成功 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「Python 供应链加固」。请给我完整脚本约 120 行：pip download 生成离线 wheelhouse、生成带哈希锁定的 requirements.txt、篡改哈希的拒装演示、file:// 离线安装验证，每步附验收命令与预期退出码。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] ⛓️ 项目 6：集成点——pre-commit 安全门

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~100 行 |
| **核心知识点** | pre-commit 钩子编排、fail-fast 设计、绕过审计（--no-verify 留痕） |
| **技术栈** | pre-commit + gitleaks + semgrep（均本机已装/待装） |
| **前置** | 项目 2、3、4 |
| **验收标准** | `git commit` 提交带密钥文件被 hook 拒绝且退出码 1；提交含 SAST 命中代码同样被拦 |
|  | 用 `--no-verify` 绕过时，包装脚本留下绕过审计记录（谁/何时/提交号），清单可查 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「pre-commit 安全门」。请给我完整配置与脚本约 100 行：.pre-commit-config.yaml 串 gitleaks+semgrep 两道钩子、--no-verify 绕过审计的 commit wrapper（记录时间/提交号到审计文件）、三条验收断言的演示脚本。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第二阶段：流水线安全门禁（项目 7-11）

> **目标**：不安全的制品过不了流水线——每道门都是可退出码的关卡

### [ ] 项目 7：镜像漏洞扫描门（trivy 阈值门禁）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | trivy image 扫描、严重度阈值退出码、.trivyignore 带过期治理 |
| **技术栈** | trivy 0.74（✅ 已实测本机安装） |
| **前置** | 项目 1 |
| **验收标准** | 靶场镜像含已知 CVE 基础镜像版本时，`trivy image --exit-code 1 --severity HIGH,CRITICAL` 退出码 1；换无 CVE 版本后退出码 0 |
|  | `.trivyignore` 中每条忽略都带 `EXPIRE_DATE` 注释，过期条目脚本可标红 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「镜像漏洞扫描门」。请给我完整脚本约 120 行：trivy 扫描靶场镜像 + 严重度阈值门禁、.trivyignore 带过期时间的忽略治理脚本（过期标红）、门禁演示（红/绿两态）验收脚本。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 8：SBOM 深水区（双格式生成与版本 diff）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | SPDX/CycloneDX 双格式、grype 从 SBOM 扫描、版本升级组件 diff |
| **技术栈** | syft 1.51（✅ 已实测）+ grype（brew 安装） |
| **前置** | 项目 7 |
| **验收标准** | 靶场镜像产出 SPDX 与 CycloneDX 双格式 SBOM，`cyclonedx` 校验器通过且组件数 >0 |
|  | 升级一个依赖重建镜像后，diff 脚本机读输出「新增/移除/版本变化」三张清单，新增组件数 ≥1 |
|  | grype 直接吃 SBOM 文件扫描的结果与扫镜像一致（CVE 编号可对上） |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「SBOM 深水区」。请给我完整脚本约 120 行：syft 生成 SPDX+CycloneDX 双格式 SBOM、grype 从 SBOM 扫描、镜像升级前后 SBOM 组件 diff 脚本（jq 机读输出新增/移除/变更三清单）、逐条验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 9：镜像签名与完整性验证（cosign key-pair）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~100 行 |
| **核心知识点** | cosign sign/verify、离线 key-pair 模式、字节级篡改检测 |
| **技术栈** | cosign 3.1.3（✅ 已实测本机安装）；本地 registry:2 容器当分发端 |
| **前置** | 项目 8 |
| **⚠️ 风险** | 零云约束下走 key-pair 模式，不用 keyless（keyless 需要 OIDC/Rekor 公网服务） |
| **验收标准** | 推到本地 registry 的靶场镜像签名后 `cosign verify` 通过；改动镜像一个字节重新推送后 verify 退出码非 0 |
|  | 私钥不在镜像/仓库任何层中出现（`trivy config` + 全层 grep 断言） |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「镜像签名与完整性验证」。请给我完整脚本约 100 行：cosign key-pair 生成（口令自动化）、对本地 registry 镜像签名与验证、篡改一字节后 verify 失败演示、私钥泄漏面检查脚本，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 10：DAST 实战（ZAP 扫描漏洞靶场）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~120 行 |
| **核心知识点** | ZAP baseline/full scan、alert 分级、DAST×SAST 结果对照 |
| **技术栈** | ghcr.io/zaproxy/zaproxy:stable（✅ 已实测拉取，arm64） |
| **前置** | 项目 1 |
| **⚠️ 风险** | full scan 对 30+ 端点靶场可能超 10 分钟，验收以 baseline scan 为主、full scan 选做；容器网络注意 `--network host` 在 OrbStack 的写法（用 `host.docker.internal` 指向宿主靶场） |
| **验收标准** | baseline scan 的 JSON 报告中，靶场 SQLi 与 XSS 端点各对应 ≥1 条 medium 及以上 alert，且 URL 与端点一一对应 |
|  | 产出 DAST×SAST 对照表：每类靶场漏洞标注「SAST 检出/DAST 检出/双检」，SSRF 类标注工具边界说明 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「DAST 实战」。请给我完整脚本约 120 行：docker 跑 ZAP baseline scan 扫宿主上的 FastAPI 靶场（OrbStack 网络写法）、JSON/HTML 报告解析成 alert 分级表、与 semgrep SAST 结果对照生成 markdown 表格，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] ⛓️ 项目 11：集成点——五道安全门的流水线

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心知识点** | 门禁编排、fail-fast、报告工件化、签名+SBOM 出厂 |
| **技术栈** | Gitea Actions 1.22（✅ 容器已在本机运行，devops.md lab 18 已教过平台基础，本课只写安全门） |
| **前置** | 项目 6-10 |
| **验收标准** | 分别向提交注入密钥/SAST 命中/高危 CVE 镜像，流水线各自在对应门失败且 exit 1、失败门之前的门正常执行 |
|  | 全绿流水线产出的镜像带 cosign 签名与双格式 SBOM 工件，可在 Gitea run artifacts 中下载 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「五道安全门的流水线」。请给我完整 Gitea Actions workflow 约 250 行：串 pre-commit 等效检查（gitleaks+semgrep）→ trivy 阈值门 → SBOM 生成 → cosign 签名 → ZAP baseline 五道门，fail-fast，每道门输出报告工件，注入式失败演示脚本与验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第三阶段：云原生加固（项目 12-17）

> **目标**：容器与 K8s 默认最小权限——攻击面在部署前被收窄

### [ ] 项目 12：容器运行时安全加固

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | non-root USER、cap-drop、read-only rootfs、seccomp profile 定制 |
| **技术栈** | Docker（OrbStack 内核 7.2.9，seccomp 可用；AppArmor Linux-only 不做） |
| **前置** | 项目 1 |
| **验收标准** | `docker inspect` 断言加固镜像：`User` 非 root、`CapAdd` 为空且 `CapDrop=ALL`、`ReadonlyRootfs=true`；加固后靶场 `pytest` 功能全过（无过度加固） |
|  | 自定义 seccomp profile 禁 `mount` 等 syscall：容器内 `mount` 调用返回 EPERM |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「容器运行时安全加固」。请给我完整 Dockerfile+脚本约 150 行：靶场镜像加固版（non-root、cap-drop ALL、read-only rootfs + tmpfs、自定义 seccomp profile 禁 mount）、docker inspect 断言脚本、功能回归 pytest，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 13：K8s Pod 安全标准（PSA restricted）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | Pod Security Admission 三档（privileged/baseline/restricted）、逐档修复路径 |
| **技术栈** | kind 0.32 + kubectl 1.33（✅ 本机已有 8 个集群在跑） |
| **前置** | 项目 12 |
| **验收标准** | 在 `enforce=restricted` 命名空间 apply 原始靶场 pod 被拒（事件含违反的 PSA 字段）；逐项修复后的 deploy 正常 Running 且 `kubectl get pod -o json` 断言 securityContext 全生效 |
|  | 每档（baseline→restricted）的 diff 修复清单落盘，能说清每项字段为什么改 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「K8s Pod 安全标准」。请给我完整清单与脚本约 150 行：kind 建 devsecops 专用集群 + restricted 命名空间、靶场 pod 三档演进清单（privileged 原始版→baseline→restricted 修复版）、PSA 拒绝事件捕获与 securityContext 断言脚本，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 14：K8s RBAC 最小权限与越权审计

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~130 行 |
| **核心知识点** | ServiceAccount/Role/RoleBinding 设计、权限爆炸半径、rbac-lookup 审计 |
| **技术栈** | kind 集群 + rbac-lookup（brew 安装） |
| **前置** | 项目 13 |
| **验收标准** | 靶场 app 的 ServiceAccount 跨命名空间 `get pod` 返回 403（kubectl as 断言），仅能读指定名称的 configmap/secret |
|  | `rbac-lookup` 全集群输出无 `*` 通配权限；审计脚本对每个 SA 列出权限并标注超需项 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「K8s RBAC 最小权限」。请给我完整清单与脚本约 130 行：靶场 app 专用 ServiceAccount+Role（最小集）、kubectl --as 越权 403 断言、rbac-lookup 全集群通配扫描与超需权限审计脚本，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 15：K8s 网络微分段（默认拒绝）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | NetworkPolicy 默认 deny、标签微分段、CNI enforcing 验证 |
| **技术栈** | kind + Calico（⚠️ 开工探活：kind 默认 CNI kindnet **不执行** NetworkPolicy，需装 Calico manifest；探活失败 fallback 用 Cilium，学习目标不变） |
| **前置** | 项目 13 |
| **⚠️ 风险** | Calico on kind 安装链路较长（官方有标准 recipe），开工先跑 `探活脚本` 验证 policy 生效再继续 |
| **验收标准** | 默认 deny 后：同命名空间无标签测试 pod `curl` 靶场超时；放行规则后 ingress 路径返回 200 |
|  | 数据库 pod 仅接受来自靶场 app 标签的连接：第三方 pod 连 DB 被拒（超时），靶场连接正常 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「K8s 网络微分段」。请给我完整清单与脚本约 150 行：kind 装 Calico 的探活脚本（验证 NetworkPolicy 真被执行）、默认 deny + ingress 放行 + DB 仅允许 app 标签的三条 NetworkPolicy、连通性正反断言脚本（超时/200 双向），附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 16：K8s 清单多引擎扫描与 Kyverno 准入

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | kics/checkov 多引擎对照、Kyverno 准入策略、CI 静态检查 vs 集群准入的互补 |
| **技术栈** | kics（brew）+ checkov（pip）+ kyverno CLI（brew，`kyverno apply` 离线测试） |
| **前置** | 项目 13 |
| **⚠️ 风险** | 与 devops.md lab 22（OPA/Conftest）的边界：本课不教策略语言原理，专注「集群内运行时准入」与多引擎结果对照；Conftest 已装的直接复用做三方对照 |
| **验收标准** | 三条 Kyverno 策略（禁 latest、必须 resources、禁 privileged）安装后，违规 deploy `kubectl apply` 被拒且事件指明命中策略；修复版 apply 成功 |
|  | kics/checkov/conftest 三引擎扫同一份靶场清单，对照表列出的重叠项与独有项各有 ≥2 条 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「K8s 清单扫描与准入」。请给我完整内容约 180 行：kics+checkov 扫描配置、Kyverno 三条策略与 kind 安装、违规/修复两版 deploy、三引擎（kics/checkov/conftest）重叠项对照表生成脚本，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 17：Vault 动态密钥与加密即服务

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | Vault 动态 DB 凭据（短 TTL 租约）、transit 加密引擎、租约吊销即时失效 |
| **技术栈** | hashicorp/vault 容器 + vault CLI 2.0.3（✅ 已实测；lab 24 只做过 SOPS 静态加密与 Vault 对照入门，本课进阶动态凭据） |
| **前置** | 项目 1 |
| **验收标准** | 启用 PostgreSQL 动态凭据引擎（postgres 容器本机已有）后，生成的临时账号 2 小时 TTL 内可连库；`vault lease revoke` 后旧凭据连接失败（退出码非 0） |
|  | transit 引擎加解密回环成功；靶场把「硬编码密钥」端点改为 transit 加密存储后，数据库文件中找不到明文（grep 断言） |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「Vault 动态密钥与加密即服务」。请给我完整脚本约 180 行：docker 起 vault dev + postgres、动态 DB 凭据引擎（2h TTL）配置、租约吊销失效验证、transit 加解密回环、靶场硬编码密钥改造为 transit 加密，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第四阶段：运行时检测与响应（项目 18-22）

> **目标**：异常行为 5 分钟内被看见、10 分钟内被处置

### [ ] 项目 18：Falco 运行时威胁检测

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | Falco 规则语法（macro/list/rule）、syscall 事件源、自定义规则与校验 |
| **技术栈** | falcosecurity/falco:latest（✅ 已实测：OrbStack VM 内 modern BPF probe 成功打开，20 秒检出 130 事件，arm64 原生） |
| **前置** | 项目 1 |
| **验收标准** | 容器内触发三类异常（起 shell、读 /etc/shadow、访问陌生 IP）各命中一条内置规则告警（3/3） |
|  | 自定义规则（靶场容器禁止出网到非白名单 IP）通过 `falco --validate`，且注入违规流量后 30 秒内产生告警 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「Falco 运行时威胁检测」。请给我完整脚本约 150 行：OrbStack 下 privileged + HOST_ROOT 挂载的 falco 启动脚本（已验证 modern BPF 可用）、三类异常行为的注入脚本、自定义规则文件与 --validate 校验、告警 JSON 落盘，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 19：K8s 审计日志检测

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | audit policy 分级（metadata/request）、可疑行为检测规则、jq 日志取证 |
| **技术栈** | kind（apiserver audit 配置）+ jq；与 devops.md lab 27 边界：lab 27 是 Loki 集中日志基建，本课专注**审计策略与安全检测**，Loki 只作可选采集端 |
| **前置** | 项目 13 |
| **验收标准** | kind apiserver 开审计后，两类可疑行为（`kubectl exec` 进靶场 pod、循环枚举 secret）各被检测脚本标红（2/2），正常 `get pod` 不误报 |
|  | audit policy 文件中 secret 读请求为 request 级（能拿到请求体），pod 读仅 metadata 级（说明最小化记录原则） |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「K8s 审计日志检测」。请给我完整内容约 150 行：kind 集群 apiserver audit policy 分级配置、可疑行为注入脚本（exec+secret 枚举）、jq 检测脚本（标红可疑/不误报正常）、取证时间线输出，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 20：漏洞持续巡检与修复 SLA

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | 基线 diff 巡检、新增 CVE 检出、修复 SLA 计时、HTML 报表 |
| **技术栈** | trivy + launchd 定时 + python 报表 |
| **前置** | 项目 7 |
| **验收标准** | 首跑建立基线后，往本地 registry 推一个含新 CVE 的镜像，下一轮巡检报告「新增 CVE」≥1 且带镜像定位；删除后巡检恢复 0 新增 |
|  | 生成的 HTML 报表含每个 CVE 的发现时间/严重度/SLA 期限/是否违期，脚本重跑幂等（重复跑不产生重复记录） |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「漏洞持续巡检与修复 SLA」。请给我完整脚本约 180 行：trivy 定时重扫本地全部镜像、与基线 JSON diff 出新增 CVE、SLA 表（严重度→期限）与违期标记、HTML 报表生成（幂等），launchd plist，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 21：密钥泄漏应急演练（全流程剧本）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | 应急响应剧本（发现→吊销→轮换→清除→复盘）、凭据失效验证、时间线取证 |
| **技术栈** | gitleaks + git-filter-repo + Vault（复用项目 17） |
| **前置** | 项目 2、17 |
| **验收标准** | 演练脚本一键执行：注入泄漏→检出告警→吊销旧 JWT secret/DB 密码→旧凭据验证失败（退出码非 0）→新凭据功能正常（pytest 过）→git 历史清除→重扫 0 泄漏，全链路 ≥7 步断言全过 |
|  | 产出复盘报告 md：时间线每个节点都有对应的原始日志/命令输出文件佐证 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「密钥泄漏应急演练」。请给我完整剧本脚本约 150 行：注入泄漏→gitleaks 检出→吊销与轮换（Vault+JWT secret）→新旧凭据正反验证→git filter-repo 清除→复盘报告生成（含时间线与证据文件），附逐步验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 22：检测到响应的自动化闭环

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | Falco webhook 输出、自动响应动作（隔离/终止）、白名单防误杀、事件入库 |
| **技术栈** | falco http_output + 本地响应服务（FastAPI）+ SQLite |
| **前置** | 项目 18 |
| **验收标准** | 靶场容器触发高危规则后 60 秒内被响应服务自动断网（`docker network disconnect`）并事件落库（时间戳+规则+容器 ID 齐全） |
|  | 白名单内容器（标注 `autoreq=ignore` 标签的合法运维容器）做同样动作不触发隔离（0 误杀） |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「检测到响应的自动化闭环」。请给我完整代码约 200 行：falco 开 http_output、FastAPI 响应服务（收告警→查白名单标签→隔离容器→SQLite 落库→打印通知）、误杀防护逻辑、注入攻击与白名单正反验收脚本。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第五阶段：攻防验证（项目 23-26）

> **目标**：每个修复都被攻击复检验证过——防御有效性的唯一证据是攻击失败

### [ ] 项目 23：漏洞利用 PoC 工程化

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~250 行 |
| **核心知识点** | PoC 脚本化（requests）、可利用性矩阵、攻击证据落盘 |
| **技术栈** | python-requests |
| **前置** | 项目 1 |
| **验收标准** | 8 类漏洞各一个 PoC 脚本，统一 runner 跑完输出利用矩阵：8/8 成功且每个 PoC 的 HTTP 请求/响应证据落盘（`poc_evidence/*.json`） |
|  | 每个证据文件包含请求、响应、判定字段（`exploited: true`），可用 jq 逐条断言 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「漏洞利用 PoC 工程化」。请给我完整代码约 250 行：对 vuln-api 靶场 8 类漏洞各写一个 requests PoC 脚本（SQLi/SSRF/pickle/弱 JWT/路径穿越/IDOR/XSS 反射/默认凭据）+ 统一 runner 输出可利用性矩阵 + 证据 JSON 落盘，附 jq 断言命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 24：修复与防回归（PoC 变 negative test）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~300 行 |
| **核心知识点** | 逐类修复（参数化查询/输出编码/SSRF allowlist/JSON 反序列化/强 JWT/沙箱路径/鉴权中间件）、修复不破坏功能 |
| **技术栈** | FastAPI + pytest |
| **前置** | 项目 23 |
| **验收标准** | 8/8 PoC 对修复版靶场全部失败（`exploited: false`），且正常功能 `pytest` 全过（无过度修复） |
|  | 8 个 PoC 已转化为 pytest 回归测试集并入 `pytest`，CI 里 `pytest tests/regression/` 可直接复跑 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「修复与防回归」。请给我完整代码约 300 行：逐类修复 vuln-api 8 类漏洞（每处修复带注释说明攻击面如何关闭）、把项目 23 的 PoC 转为 pytest negative 回归测试集、修复前后对照矩阵脚本，附验收命令（8/8 攻击失败 + 功能全过）。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 25：容器逃逸对抗演练

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~180 行 |
| **核心知识点** | privileged/hostPath/docker.sock 三种危险配置、逃逸取证、加固对抗 |
| **技术栈** | Docker（逃逸落点是 OrbStack Linux VM 不是 macOS，报告需声明此边界） |
| **前置** | 项目 12 |
| **验收标准** | 三种危险配置各一个逃逸 PoC：都能从容器内读到 VM 宿主层文件（3/3 成功并截图/落盘证据） |
|  | 按项目 12 加固配置重跑同三 PoC：0/3 成功，且加固版靶场功能正常 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「容器逃逸对抗演练」。请给我完整脚本约 180 行：privileged/挂载 /（hostPath 等价物）/docker.sock 三种危险配置容器 + 各自逃逸 PoC（读宿主层文件取证）+ 项目 12 加固配置复跑对照脚本，报告里声明 OrbStack VM 边界，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 26：Nuclei 攻击面扫描与模板门禁化

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~150 行 |
| **核心知识点** | nuclei 模板扫描、误报甄别、有效模板纳入流水线门 |
| **技术栈** | nuclei（brew 安装，模板库走国内可达源下载） |
| **前置** | 项目 23 |
| **验收标准** | nuclei 扫修复前靶场命中 ≥2 个已知漏洞（与 PoC 端点对应）；对修复版复扫同模板 0 命中 |
|  | 3 条命中结果的人工甄别记录落盘（真实/误报判定+依据），确认有效的模板已加入项目 11 流水线门并演示拦截 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「Nuclei 攻击面扫描」。请给我完整脚本约 150 行：nuclei 对 vuln-api 修复前后两版扫描、与 PoC 端点对照、3 条命中的误报甄别记录模板、有效模板接入 Gitea 流水线门的 workflow 片段，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 🗂️ 第六阶段：治理与交付（项目 27-30）

> **目标**：安全状态可度量、事件可复盘、全链路可演示

### [ ] 项目 27：合规即代码（CIS benchmark 对标）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | CIS Docker/K8s benchmark、docker-bench-security、自写检查项、差距报告 |
| **技术栈** | docker/docker-bench-security（✅ 镜像已实测拉取；OrbStack 下部分宿主检查项 N/A 属预期，报告需注明原因）；与 devops.md lab 25 边界：lab 25 是 conftest 门禁流水线，本课对标 CIS 基线并产出差距报告 |
| **前置** | 项目 13、16 |
| **验收标准** | docker-bench 与自写脚本（PSA 是否启用/RBAC 是否最小/NetworkPolicy 是否默认 deny 三项）合并产出差距报告，含 PASS/WARN/FAIL/N-A 计数与 N-A 原因 |
|  | 报告中 3 个 FAIL 项修复后复跑：对应项转 PASS，其余项结果不变（无回归） |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「合规即代码」。请给我完整脚本约 200 行：docker-bench-security 跑本机 OrbStack（N-A 项说明）、CIS K8s 三项自写检查（PSA/RBAC/netpol）、合并差距报告生成（计数+修复建议）、修复前后复跑对照，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 28：安全度量看板（从真实数据出报表）

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | 安全指标定义（门禁拦截率/检出率/CVE MTTR/告警量）、指标可溯源、幂等报表 |
| **技术栈** | python + jq，数据源全部来自前序项目真实产物 |
| **前置** | 项目 6-22（汇总线） |
| **验收标准** | 看板 5 个指标（pre-commit 拦截数、SAST 检出率、trivy 高危 MTTR、Falco 告警数、流水线拦截率）每个都能用脚本追溯到具体原始数据文件并数值一致 |
|  | 报表脚本重跑 3 次输出 byte 级一致（幂等），静态 HTML 可离线打开 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「安全度量看板」。请给我完整代码约 200 行：从前序项目产物（gitleaks/semgrep/trivy/falco/流水线日志）汇总 5 个指标的采集脚本、溯源断言（指标↔原始文件）、幂等静态 HTML 看板生成，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 项目 29：事件响应端到端演练与 postmortem

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~200 行 |
| **核心知识点** | 攻击注入→检出→响应→取证时间线→postmortem 全流程、证据链 |
| **技术栈** | 复用项目 18/19/22/23 的全部产物 |
| **前置** | 项目 22、23 |
| **验收标准** | 一键演练：注入一次攻击→Falco/审计日志检出→项目 22 自动响应→取证脚本从 git log/镜像层/审计日志构建时间线→生成 postmortem，全流程 ≤10 分钟且每步断言过 |
|  | postmortem 时间线每个节点都引用了落盘的原始证据文件（路径存在且非空，脚本断言） |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「事件响应端到端演练」。请给我完整脚本约 200 行：攻击注入→检出（falco+审计）→自动响应→三源取证（git/镜像层/审计日志）时间线构建→postmortem 生成（证据文件路径断言），全流程一键跑，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

### [ ] 🏁 项目 30：终极串联——DevSecOps 全链路攻防演示

| 项目信息 | 详情 |
|:---|:---|
| **行数** | ~300 行 |
| **核心知识点** | 全生命周期串联、12 场景断言编排、演示报告 |
| **前置** | 项目 1-29 |
| **验收标准** | 一条脚本跑完 12 个场景断言全过：提交带密钥被 pre-commit 拦→绕过提交→流水线五门在对应门拦→修复后全绿出签名镜像+SBOM→部署进 restricted 命名空间→攻击注入→Falco+审计检出→自动响应隔离→应急吊销轮换→度量看板刷新→合规报告更新→postmortem 生成 |
|  | 输出 `demo_report.md`：每个场景的断言结果+关键日志摘录，新人可按报告独立复跑 |

**🤖 开始提示词**：
> `我要开始 DevSecOps 项目「终极串联：全链路攻防演示」。请给我完整编排脚本约 300 行：串起清单全部能力——pre-commit 门、五道流水线门、签名+SBOM、restricted 部署、运行时检出与自动响应、应急轮换、度量/合规/postmortem 刷新，12 场景断言，输出 demo_report.md，附验收命令。只输出代码。`

**完成日期**：________
**踩坑记录**：________

---

## 📅 周计划

| 周次 | 内容 | 项目数 |
|:---|:---|:---:|
| **第 1 周** | 项目 1-3（靶场搭建 + 密钥检测 + SAST） | 3 |
| **第 2 周** | 项目 4-6（SCA + 供应链 + ⛓️ pre-commit 门） | 3 |
| **第 3 周** | 项目 7-9（trivy 门 + SBOM + cosign） | 3 |
| **第 4 周** | 项目 10-11（DAST + ⛓️ 五道门流水线） | 2 |
| **第 5 周** | 项目 12-13（容器加固 + PSA） | 2 |
| **第 6 周** | 项目 14-15（RBAC + 网络微分段） | 2 |
| **第 7 周** | 项目 16-17（扫描/准入 + Vault 动态密钥） | 2 |
| **第 8 周** | 项目 18-19（Falco + 审计日志） | 2 |
| **第 9 周** | 项目 20-22（巡检 SLA + 应急演练 + 自动响应） | 3 |
| **第 10 周** | 项目 23-24（PoC 工程化 + 修复防回归） | 2 |
| **第 11 周** | 项目 25-26（逃逸对抗 + nuclei） | 2 |
| **第 12 周** | 项目 27-30（合规 + 看板 + 演练 + 🏁 终极串联） | 4 |

## 🏆 里程碑

- [ ] **完成项目 1-6** → 🔑 「左移守门员」：密钥与漏洞在提交前就被拦下
- [ ] **完成项目 7-11** → 🚪 「门禁工程师」：五道安全门流水线，红的制品出不了厂
- [ ] **完成项目 12-17** → 🏰 「云原生加固师」：容器与 K8s 默认最小权限，攻击面部署前收窄
- [ ] **完成项目 18-22** → 👁️ 「运行时哨兵」：异常 5 分钟可见、10 分钟可自动处置
- [ ] **完成项目 23-26** → ⚔️ 「红队验证者」：每个修复都被攻击复检验证过
- [ ] **完成项目 27-30** → 🏆 「DevSecOps 全栈工程师」：可度量、可复盘、全链路可演示

## 🔧 环境配置

```bash
# 0. 已就绪（2026-10-21 实测核验）
#    docker 29.8.2（OrbStack，内核 7.2.9 带 BTF，eBPF 友好）/ kind 0.32.0 / kubectl 1.33.9
#    trivy 0.74.0 / syft 1.51.1 / cosign 3.1.3 / vault CLI 2.0.3 / conftest / jq / yq
#    python 3.13.9 / brew / gitea:1.22 容器运行中（项目 11 载体）
#    镜像已拉：falcosecurity/falco:latest（✅ modern BPF 实测检出 130 事件）
#              ghcr.io/zaproxy/zaproxy:stable（3.64GB）/ docker/docker-bench-security
#    ❌ owasp/juice-shop：本机三个 registry mirror 均拉不动（EOF），DAST 目标改用自建靶场

# 1. 需安装（按阶段分批装，不必一次全装）
# 阶段一：
brew install gitleaks osv-scanner && pip3 install semgrep pip-audit pre-commit
# 阶段二：
brew install grype
# 阶段三：
brew install kics rbac-lookup kyverno && pip3 install checkov
# 阶段五：
brew install nuclei && brew install git-filter-repo   # git-filter-repo 项目 2/21 用

# 2. 每项目开工前统一检查
docker info > /dev/null && kind get clusters && echo "[ok] docker+kind 就绪"
```

## ⚠️ 与已有清单的关系

| 已有清单/实验 | 关系 |
|:---|:---|
| devops.md lab 22（OPA/Conftest 策略即代码） | 项目 16 不重复教策略语言，专注 Kyverno **集群内运行时准入** + kics/checkov 多引擎对照；Conftest 直接复用当对照引擎 |
| devops.md lab 23（IaC 安全扫描 tfsec/trivy） | 本清单**不做 IaC 扫描**（已覆盖），专注应用层/容器/K8s/运行时纵深 |
| devops.md lab 24（SOPS+age 静态加密） | 项目 17 是进阶：Vault **动态短时凭据**与 transit 加密，静态文件加密不再讲 |
| devops.md lab 14（SBOM+cosign 流水线签发） | 项目 8/9 是深水区：SBOM 组件 diff、离线 key-pair 篡改对抗视角；签发流程基础不重复 |
| devops.md lab 11（镜像瘦身） | 项目 12 是**安全视角**加固（non-root/caps/read-only/seccomp），尺寸不是目标 |
| devops.md lab 25（合规流水线）/ lab 09（InSpec） | 项目 27 对标 CIS Docker/K8s benchmark 出差距报告，是基线对照进阶 |
| devops.md lab 27（Loki 集中日志） | 项目 19 专注**审计策略与安全检测规则**，Loki 仅作可选采集端 |
| devops.md lab 16-19（Jenkins/Gitea/Woodpecker） | 项目 11 直接复用已搭好的 Gitea Actions，**不教 CI 平台**，只写安全门 |
| cicd.md 项目 7（OIDC）/ 项目 8（action 供应链） | 本清单零云不涉及 OIDC；action 供应链不重复，pip 侧哈希锁定在项目 5 深化 |
| cicd.md act 本地回路 | 本清单统一用 Gitea Actions 载体，不引入 act |

## 📚 能力覆盖速查表（2026-10-21 实测）

| 能力/工具 | 计划 | 实测结论 |
|:---|:---|:---|
| gitleaks / semgrep / pip-audit / osv-scanner / grype / kics / checkov / nuclei / rbac-lookup | brew/pip 安装 | ⚠️ 待安装（常规渠道，无平台障碍） |
| trivy 0.74 / syft 1.51 / cosign 3.1.3 / vault CLI 2.0.3 | 镜像与依赖扫描、签名、密钥 | ✅ 实测已装 |
| Falco modern BPF（OrbStack VM） | 运行时检测（项目 18/22/29） | ✅ 实测通过：privileged + HOST_ROOT 挂载，20 秒检出 130 事件 |
| OWASP ZAP stable（ghcr，arm64） | DAST（项目 10/11） | ✅ 实测拉取成功（3.64GB） |
| docker-bench-security on OrbStack | CIS Docker 对标（项目 27） | ✅ 镜像已拉；⚠️ 宿主检查项部分 N/A 属预期，验收按"N-A 需注明原因"执行 |
| kind + Calico（NetworkPolicy enforcing） | 微分段（项目 15） | ⚠️ 开工探活：kindnet 不执行 policy，需装 Calico；fallback Cilium |
| seccomp profile（OrbStack 内核 7.2.9） | 容器加固（项目 12） | ✅ Linux 内核特性，VM 内可用（AppArmor 不做，Linux 宿主 only） |
| owasp/juice-shop 镜像 | 第三方靶场 | ❌ 本机三 mirror 均 EOF 拉不动 → 自建 vuln-api 即 DAST/SAST 共用靶场 |
| GitHub 侧工具（CodeQL/GHAS/keyless cosign） | — | ❌ 本清单零云约束排除；keyless 签名需公网 OIDC，用 key-pair 替代 |

## 📝 每日日志

| 日期 | 项目 | 耗时 | 收获 | 踩坑 |
|:---|:---|:---:|:---|:---|
| | | | | |
