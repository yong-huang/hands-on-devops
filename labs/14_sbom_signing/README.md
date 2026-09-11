# 14 · SBOM + cosign：给制品配身份证与防伪签

> 镜像推上 registry 之后，"里面装了什么"、"还是我推的那份吗"——这两个问题在出事之前
> 没人问，出事之后答不上来。SBOM（软件物料清单）回答前者：25 个包全部可枚举；
> cosign 签名回答后者：签名绑定 digest，同 tag 覆盖攻击当场现形。

## 1. 为什么需要它

软件供应链事件的两个经典剧本：

- **里面有什么没人知道**：Log4Shell 爆出时，答案"哪些镜像用了 log4j2"让全球运维彻夜
  grep——有 SBOM 的团队是一条 jq 查询；
- **tag 被覆盖**：`myapp:1.0.0` 被重新推成恶意版本，tag 不变、内容已换。
  digest 引用 + 签名让"覆盖"失效：签名绑定的是 digest，内容变则验签必红。

## 2. 总览：核心机制一图看懂

![sbom signing](images/sbom_signing.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/14_sbom_signing/images/sbom_signing.html)
> （或本地打开 [`images/sbom_signing.html`](images/sbom_signing.html)）。

看图方法：生产线（上行）从构建到入仓，途中完成 SBOM 归档与签名；信任链（下行）
是拉取侧的 verify——绿则放行部署，红（同 tag 覆盖）则当场拦截。

## 3. 快速开始

```bash
cd labs/14_sbom_signing
./sbom_signing.sh            # sbom → sign → tamper → clean
./sbom_signing.sh tamper     # 单独重放攻击演示
```

真实输出（关键节点）：

```
=====> [sbom] syft 生成 SBOM
        [ok] SBOM 已生成：artifacts/sbom.spdx.json（25 个包）
=====> [sign] cosign 签名 + 验签
        [ok] 密钥对已生成（tmp/cosign.key 绝不入库）
        [ok] verified
        {"name":"demo/signed","tags":["sha256-b757…","1.0.0"]}   # 签名就是同仓库的 .sig tag
=====> [tamper] 同 tag 覆盖恶意镜像
        [检出] cosign verify 失败（exit=10）—— 签名与 digest 绑定，篡改必被识破
```

## 4. 核心概念

### 4.1 SBOM：软件的配料表

`syft <image> -o spdx-json` 枚举镜像内全部软件包（OS 包 + 语言级依赖），产出
SPDX 标准格式。它回答"Composition 分析"：漏洞披露当天，一条 jq 就列出受影响的
全部制品；这也是 SLSA / 执行品控框架的基础工件。

### 4.2 cosign：签名与 digest 绑定

```bash
COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix tmp/cosign
COSIGN_PASSWORD="" cosign sign --key tmp/cosign.key --yes "$IMG"
COSIGN_PASSWORD="" cosign verify --key tmp/cosign.pub "$IMG"   # CI 里就是这一条
```

签名对象是 **digest**（内容寻址），不是 tag。签名本身以 `sha256-<digest>.sig` tag
存回同一 registry——无需额外签名服务器。篡改演示：同 tag 重新推恶意镜像，
digest 变化 → verify 退出码 10（非零）→ 门禁拦截。

### 4.3 密钥管理与 CI 用法

- 私钥永不入库（`.gitignore` 里有 `cosign.key`）；生产放 KMS/HSM 或云 KMS，
  cosign 原生支持 KMS URI；
- 公钥随仓库分发；CI 部署 job 第一步跑 verify，非零即失败；
- 免密钥模式可用 keyless（Fulcio/Rekor），本机靶场用密钥对演示。

## 5. 命令关键字段

```bash
syft "$IMG" -o spdx-json > sbom.spdx.json   # SPDX JSON 供机器消费；-o table 给人看
cosign sign --key tmp/cosign.key --yes "$IMG"   # --yes 跳过交互确认（CI 必须）
cosign verify --key tmp/cosign.pub "$IMG"       # 退出码非零 = 拦截
```

坑清单：

- **坑① cosign 密码提示卡死 CI**：`COSIGN_PASSWORD=""`（空密码 + 环境变量）或 KMS；
- **坑② 签名 tag 也占仓库**：每个 digest 产生 `.sig` tag，保留策略（实验 13）要连
  签名一起清理；
- **坑③ tag 引用签不到点子上**：`cosign sign localhost:5500/demo/signed:1.0.0` 会先
  解析 digest 再签——验证时若 tag 被覆盖，命中的是新 digest，验签失败（这正是我们要的）。

## 6. 文件结构

```
14_sbom_signing/
├── README.md              # 本教程
├── sbom_signing.sh        # sbom / sign / tamper / clean
├── artifacts/             # 运行时产物：sbom.spdx.json（gitignore）
├── tmp/                   # cosign 密钥对（gitignore，绝不入库）
└── images/                # 图三件套（json/html/svg）
```

## 7. 深入要点

- **SBOM 的两种主流格式？** SPDX（Linux 基金会，本实验）与 CycloneDX（OWASP）；
  核心都是"包名+版本+校验和+依赖关系"，选型看下游工具链兼容。
- **cosign 如何防 tag 覆盖？** 签名绑定 digest；tag 只是 digest 的可变别名。
  验签时 tag 解析到新 digest → 找不到匹配签名 → 非零退出。
- **签名私钥放哪里？** 开发演示用本地密钥对；生产用 KMS/HSM（cosign KMS 支持）或
  keyless（OIDC 短身份 + 透明日志 Rekor），避免私钥落地。
- **SBOM/签名怎么进流水线？** 构建 job：syft 生成 SBOM、cosign 签名并归档；
  部署 job：cosign verify 通过才允许 kubectl/docker 上线（实验 25 三道门之签名门）。

## 8. 总结

制品现在有了完整身份证件链：可重复的构建（12）、受治理的仓库（13）、透明的成分
（SBOM）与防伪签（cosign）。实验 15 把 11-14 串成一条手工发布流水线：
`make release VERSION=x` 一条命令走完构建→SBOM→签名→推送→部署→验证，产物全程可追溯。
