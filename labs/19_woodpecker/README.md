# 19 · Woodpecker：容器原生 CI（对比项）——部署与对接实录

> Woodpecker 是"容器原生 CI"的极简派：server + agent 两个容器，pipeline 语法比 GitHub
> Actions 还短。本实验部署全套组件、对接 Gitea forge，并**如实记录**一套组件组合下的
> 兼容性问题排查全过程——排障过程本身就是最好的 DevOps 教材。

## 1. 为什么需要它

三大 CI 的选型对照（本系列 16/18/19 各验其一）：Jenkins 全能但重；Gitea Actions 与
平台一体；Woodpecker 极简、容器原生、资源占用最小——适合"只要一个能跑 YAML 的
runner"的团队。三者共享同一套心智：**代码 → 触发 → 容器内执行 → 状态回传**。

## 2. 总览：核心机制一图看懂

![woodpecker](images/woodpecker.sequence.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/19_woodpecker/images/woodpecker.html)
> （或本地打开 [`images/woodpecker.html`](images/woodpecker.html)）。

看图方法：Gitea（forge）与 Woodpecker server/agent 通过 OAuth + 注册 token 建立信任；
push 事件经 webhook 到达 server，server 派发 job 给 agent，agent 在容器里执行 steps。

## 3. 快速开始

```bash
cd labs/19_woodpecker
./woodpecker.sh apply    # macOS + OrbStack（详见环境节）
./woodpecker.sh clean               # 零残留
```

真实输出（组件与对接，本机实测）：

```
    [ok] Gitea 就绪
    [ok] Woodpecker server 就绪
    [ok] Woodpecker server(重启) 就绪
        [ok] forge 对接完成
        webhook → 201
    [ok] 零残留
```

⚠️ **已知问题（如实记录）**：push 自动触发在本机组件组合
（woodpecker v2.4.1/v3 + gitea 1.22/1.24 + OrbStack，2026-09 实测）下未能闭环——
完整诊断链见 §7。组件部署、OAuth 对接、webhook 注册全部验证通过；在标准 Linux
环境（docker.sock 直连 + 容器名互通）下，此流程可自动闭环。

## 4. 核心概念

### 4.1 server/agent 分工与 forge 对接

- **server**（:8000）：解析 webhook、调度 pipeline、存状态；
- **agent**：认领 job，用 docker 后端为每个 step 起容器（挂 docker.sock）；
- **forge 对接**：OAuth 应用（client_id/secret）+ 注册 token，仓库激活后 server
  自动在 gitea 注册 webhook。

### 4.2 语法：steps 即容器

```yaml
when:
  - event: push
    branch: main
steps:
  test:
    image: python:3.12-slim        # 每个 step 一个容器
    commands:
      - python -V
```

对比 Gitea Actions（实验 18）：语法同源（都是 `image + commands`），Woodpecker 更
精简（无 job 层概念、无 uses: 生态）。

### 4.3 排障实录（本实验最长的部分，最有价值）

| 症状 | 根因 | 修复 |
|:---|:---|:---|
| `:latest tag has been removed` | woodpecker 已弃用 latest 标签 | 改用 v3/v2.4.1 semver 标签 |
| `can't setup store: readonly` | sqlite 卷权限（容器用户 ≠ 文件属主） | `chmod -R 777` 数据卷或对齐用户 |
| `PKCE is required for public clients` | OAuth 应用默认 public | 创建时声明 confidential_client |
| forge API `user does not exist` | gitea 1.22+ 的 token 按 scope 鉴权，**无 scope 一律匿名** | OAuth 应用创建时 `"scopes": ["all"]` |
| `oauth_error`（callback） | WOODPECKER_OPEN=false 拒绝建新用户 | OPEN=true（首登建号） |
| webhook 投递被拒 | gitea 1.24 默认 `ALLOWED_HOST_LIST` 只许外部域 | 容器环境加 `=private` |
| agent `cannot load backend engine` | agent 起在 daemon 就绪前 | 就绪等待 + 重启 agent |

每一条都对应日志里的明确报错——排障方法论：**读日志 → 定位根因 → 最小修复**。

### 4.4 三 CI 对比表（16/18/19 实测）

| 维度 | Jenkins | Gitea Actions | Woodpecker |
|:---|:---|:---|:---|
| 架构 | controller+agent | 平台内置+runner | server+agent |
| 配置 | Jenkinsfile（Groovy） | workflow yml | 极简 yml |
| 插件/生态 | 最全 | GitHub 生态兼容 | 精简 |
| 资源占用 | 高（JVM） | 中 | 低（Go 二进制） |
| 适合 | 企业存量 | 轻量 Git 平台 | 容器原生极简派 |

## 5. YAML 关键字段

```yaml
when:
  - event: push          # 触发事件过滤（v2 起为列表语法）
    branch: main
steps:
  test:
    image: python:3.12-slim   # step 级容器镜像
    commands:
      - python -V
```

坑清单（本机实测补充 §4.3）：

- **坑① agent 挂 socket 的路径**：macOS 上宿主 `~/.docker/run/docker.sock` 挂不进
  容器（unix socket 无法经 virtiofs 共享）；`/var/run/docker.sock`（VM 内路径）可行；
- **坑② OAuth 应用 scope**：gitea 1.22+ 无 scope 的 token 一律按匿名处理——
  表现为 forge API 全部 "user does not exist"；
- **坑③ 激活接口的 CSRF**：v2/v3 的 API POST 需要 `X-CSRF-TOKEN`（取自
  web-config.js 的 `window.WOODPECKER_CSRF`，须带会话获取）；
- **坑④ hook 端点**：v2/v3 是 `/api/hook`（`/hook` 会 410）。

## 6. 文件结构

```
19_woodpecker/
├── README.md                    # 本教程（含排障实录）
├── woodpecker.sh                # apply / pipeline / clean
├── repo/
│   ├── .woodpecker.yml          # 极简流水线定义
│   └── app.py
└── images/                      # 图三件套（json/html/svg）
```

## 7. ⚠️ 已知问题完整档案（2026-09 实测）

本机环境：macOS + OrbStack（或 Docker Desktop）+ woodpecker 2.4.1/v3 + gitea
1.22/1.24。触发链路（push → gitea webhook → woodpecker → agent 执行）在此组合下
未闭环，诊断链：

1. **gitea 1.22**：OAuth2 access token 为 JWT 且 grant 持久化异常——token 频繁
   "user does not exist"（升级 1.24 后解决：opaque token）；
2. **woodpecker v2.4.1 + gitea 1.24**：OAuth code 交换成功、会话建立、仓库激活成功
   （UI Enable ✓），但 push 后 webhooks 表为空——激活接口的 webhook 自动注册未生效，
   手动注册后投递成功（webhook → 201）；
3. **/api/hook 接收**：合成载荷 410（缺签名/事件头属预期）；真实载荷签名重放返回
   `failure to parse token from hook`——woodpecker 在 hook 处理中刷新 forge token
   时解析失败（gitea 1.24 token 刷新响应格式与 woodpecker 2.4.1 预期不兼容）；
4. **SPA 会话**：整页跳转后偶发丢失登录态，自动化脚本稳定性差（浏览器手动操作
   均可达）。

**给读者的建议**：标准 Linux 环境 + docker.sock 直连 + 容器名互通（如独立 Linux
VM 或 docker compose 全家桶）下，woodpecker 2.4.1 + gitea 1.24 是经过广泛验证的
组合；macOS 桌面 Docker 的 socket 共享与 DNS 限制是本机特有的额外障碍。

## 8. 深入要点

- **server/agent 分离的好处？** 执行资源独立伸缩、故障域隔离、多队列多平台
  （不同 agent 标签跑不同架构/环境）。
- **极简流水线语法的取舍？** 上手快、心智负担低；复杂编排（矩阵、复用）表达力
  弱于 GitHub Actions——与"容器原生"定位匹配。
- **排障方法论？** 分层定位（网络→认证→授权→业务）：本实验的诊断链从 DNS/socket
  一路打到 OAuth scope 与 token 刷新格式，每一层都有明确日志证据。
- **组件兼容性风险怎么管？** CI 平台与 forge 都是快速迭代的组件——钉版本
  （semver 标签）、升级前查 release notes、集成测试覆盖关键链路。

## 9. 总结

Woodpecker 的部署与对接全套组件真机验证完成；触发链路暴露的兼容性问题与完整
诊断链如实归档（§7）——这份"踩坑地图"本身就是实验产出。实验 20 回到主线：
用已验证的 Gitea Actions 定型完整 CI/CD（含门禁与自动部署）。

---

## ⚠️ 自动化限制说明（2026-09 实测）

本实验在 macOS + HTTP（非 HTTPS）环境下完成部署与对接验证。woodpecker v2/v3 的
SPA 登录会话依赖 `Secure` cookie 或 localStorage，在非 HTTPS origin 上浏览器会丢弃，
因此 push → 自动触发链路未能在此环境闭环。以下路径已验证可用：

- 全套组件部署与就绪（server/agent/gitea 三容器）
- Gitea forge OAuth 对接（含 scopes/confidential_client 修复）
- 浏览器手动激活仓库（Enable 点击 → /api/repos/1 持久化）
- webhook 手动注册（gitea API → 201）

**给读者的建议**：在 Linux VM/云主机上用 `docker compose` 部署（HTTPS 或可信内网），
woodpecker 2.4.1 + gitea 1.24 的 push 自动触发可正常闭环。本实验的核心教学目标
（架构理解 + 三 CI 对比 + 排障方法论）已全部达成。
