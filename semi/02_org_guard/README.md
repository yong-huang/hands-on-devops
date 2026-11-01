# 02 · 设计部门工作区：Group 层级与 IP 保护策略

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 2 · 阶段一「入职第 1 周——把半导体内网立起来」
> 组树即权限边界：Group/子组 + 成员角色矩阵 + 受保护分支 + 平台级 server hook 拦截大文件直推
> 全部断言在 `org_guard.sh verify`：三条**真实 git push**（受限用户撞 main / 100MB 撞 hook / 小文件放行），全过打 `[ok]`

## Background

半导体公司的核心资产是芯片源码、PDK 工艺库、版图文件——IP 保护的落点不是口号，是仓库平台的权限结构：谁能进哪个组、谁能直推哪个分支、多大的文件允许进 git 历史。

GitLab 免费版（CE）没有 push rules（那是 Premium 功能），但平台级拦截有自己的路：**server hooks**——Git 服务端在收到 push 时执行的脚本。

`pre-receive` 阶段看到的是"这次 push 要引入哪些新对象"，在这里量体积、拒超大文件，就等于给整个平台装了门禁。本实验同时把组织结构（组树/成员矩阵）和这道门禁一起立起来，全部声明在 `configs/org.yaml` 里，脚本幂等 apply。

## What

心智模型一句话：**org.yaml 是权限的源代码，GitLab 是它的编译产物**。apply 出来的平台结构：

```
semi（半导体设计部门，root=Owner 50）
└── ip（IP 资产库）
    └── design（设计组）
        ├── 成员：dev1 = Developer(30) —— 可推普通分支，动不了受保护分支
        └── push-lab（Push 靶场）
            └── main：push_access=0（谁都不许直推，只许走 MR）+ merge_access=40
```

权限数字是 GitLab 的成员级别：30=Developer、40=Maintainer、50=Owner；MR（Merge Request）即合并请求——main 不许直推，改动只能开 MR 由 Maintainer 合入。

两道闸各管一件事：

| 闸 | 管什么 | 实现层 |
|:---|:---|:---|
| Protected branch `main` | 谁**有资格**写 main（本实验：谁都无权直推） | GitLab 内建钩子链（由 gitlab-shell 组件执行——它管 git 服务端的认证与钩子） |
| pre-receive server hook | 什么**内容**允许入库（>50MB blob 一律拒绝） | 我们写的脚本（装在 Gitaly——GitLab 的 Git 存储服务——的全局 hooks 目录） |

验证方法：`./org_guard.sh status` 看组树与 hook；`./org_guard.sh verify` 用真实 git push 撞这两道闸。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 平台级"大文件必须走 LFS"纪律（本实验） | 全局 pre-receive server hook，一次安装全仓库生效（LFS = Git Large File Storage，git 的大文件旁路存储，仓库里只留 ~130B 指针） |
| 只想保护个别仓库 | 同一脚本装到该仓库的 `custom_hooks/`（遗留通道，GitLab 19 仍兼容） |
| 要按文件类型/分支维度细化规则（如 .lib 只能进特定组） | server hook 里读 ref 名与路径即可扩展；或上 Premium push rules |
| 只想通知不想拦截 | webhook + CI 检查（事前提醒，拦不住）——语义弱于 server hook |

## Quick Start

前置：项目 1 的 GitLab 平台在线（`cd ../01_gitlab_up && ./gitlab_up.sh up`，首次启动 4-6 分钟）；`pip install python-gitlab pyyaml`（清华源已配——pyyaml 是 org.yaml 声明解析的依赖，漏装会在 up 末步才崩）。

```bash
./org_guard.sh up      # 平台配置演进 + 装 hook + root PAT + apply org.yaml（首次约 3 分钟）
./org_guard.sh verify  # 三条真实 git push 验收断言
./org_guard.sh status  # 组树/成员/hook 速览
./org_guard.sh clean   # 拆本实验装的东西（组 semi 留给项目 3+）
```

`verify` 的真实输出（2026-10-29 实测）：

```
=====> [verify] 验收① 受限用户直推 main → 必须被拒
  [ok]   dev1 直推 main 被拒（exit≠0 + protected branch 提示）
         remote: GitLab: You are not allowed to push code to protected branches on this project.

=====> [verify] 验收② 100MB 大文件直推 → server hook 必须拒绝并提示 LFS
  [ok]   100MB 直推被 pre-receive 拒绝且提示 LFS
         remote: [pre-receive] 拒绝：refs/heads/feature/big-1793287933 引入超大文件 big.bin（100MB > 50MB）
         remote: [pre-receive] 大文件请走 LFS：git lfs track "<模式>" 后重新提交（指针仅 ~130B，不受此限制）

=====> [verify] 验收③ 普通小文件推 feature 分支 → 放行
  [ok]   小文件推送成功（hook 放行 + 分支未保护）

[ok] 项目 2 全部验收断言通过
```

`up` 会生成 `dev1` 用户（密码在 `configs/org.yaml` 的 users 段）——浏览器开 <http://localhost:28200> 用 dev1 登录，能直观看到：推不了 main、看得见 push-lab。

root 的 API token（PAT，Personal Access Token 个人访问令牌）存在 `.root-token`（已 gitignore，由 rails runner——容器内直跑 Rails 脚本的管理通道——动态签发）。

## How It Works

### 幂等 apply：409 不是错误，是"已存在"

`scripts/bootstrap_org.py` 对每组/每用户/每项目先试创建、捕获"已存在"再改走查询——重复跑 `up` 输出 `[  =] 组已存在` 并继续。

声明式工具（Terraform/Ansible）同款思路的最小实现：**声明期望状态，apply 负责对齐**。首提交用 commits API（web 通道，按"允许合并"鉴权），所以可以在保护 main 之后再写入——git push 做不到这一点，这正是两通道语义差异的活教材。

### server hook 的输入输出协议

pre-receive 从 stdin 逐行读 `<旧sha> <新sha> <ref>`，退出非 0 = 整个 push 拒绝。

git push 的对象先进**隔离区**（quarantine），hook 里 `git rev-list --objects $new --not --all` 列出的就是"这次新引入"的对象。

量到 >50MB 的 blob 就写 stderr（客户端显示 `remote: ...`）并 exit 1。删分支（新 sha 为全 0）没有新对象，直接放行。

### GitLab 19 的 hook 安装姿势（本次实测最大的坑）

全局 hook 的位置**不是** `custom_hooks/pre-receive`，而是：

```
/var/opt/gitlab/gitaly/custom_hooks/
└── pre-receive.d/          ← 必须是 <类型>.d 子目录，裸文件不被扫描
    └── 50-block-huge-blobs ← 文件名任意，按字母序执行；属主必须 git:git
```

实测证据：裸文件（哪怕 chown git）push 照样放行；放进 `.d/` 子目录立即生效。

仓库级旧式 `custom_hooks/pre-receive` 裸文件反而仍被兼容——新全局机制与旧仓库机制在这里行为相反，只看文档不看实测必踩。`install_hook()` 同时做了 chown git:git（Gitaly 拒绝执行非 git 属主的 hook）。

### 平台配置演进：01 的 gitlab.rb 是唯一真源

全局 hooks 目录靠一段 `gitaly['configuration']` 的 hooks 配置，`org_guard.sh` 幂等地把它追加进 `../01_gitlab_up/configs/gitlab.rb`（grep 过就跳过）。

追加后执行 `gitlab-ctl reconfigure`——把 gitlab.rb 渲染为各服务真实配置的 Omnibus 命令。

**平台配置只有一份**，后续实验继续在这份文件上演进，`clean` 会把这段回滚。

## Pitfalls & Q&A

**坑 1：全局 hook 装在 `custom_hooks/pre-receive` 完全不生效。** GitLab 19 要求放 `custom_hooks/pre-receive.d/` 子目录且属主 git:git（详见 How It Works 第三节）。

排查手法：per-repo `custom_hooks/` 裸文件是"金标准探针"——它若生效而全局不生效，就是路径/属主问题。

**坑 2：手工调试 hook 时 git 报 "dubious ownership"。** 手动跑 hook 的进程是 root，仓库属主是 git——这是**调试环境**的问题，不代表 hook 坏。

`docker exec -u git` 还原真实执行身份再测。本项目 ② 断言第一次"成功"就是这么误判出来的（push 真正失败原因被吞）。

**Q：为什么 dev1 能推 feature 分支却推不了 main？** 角色矩阵给的是 Developer(30)：普通分支随便推。

main 的 push_access_level=0 是"无访问"，比角色更细的分支级开关，两者取更严者。

**Q：gitlab.rb 追加配置后为什么要 reconfigure？** gitlab.rb 只是"源代码"，Omnibus 的 reconfigure（内嵌 chef）把它渲染成各服务的真实配置（这里是 gitaly 的 config.toml `[hooks]` 段）。

不 reconfigure，它就只是注释好看的文件。

**Q：token 为什么用 rails runner 签发而不是密码换？** PAT 无法二次读取（只存摘要），丢了只能重签。

rails runner 直连 DB 以容器管理员身份运行，不依赖 root 密码（24h 后 initial_root_password 就删了）。`org_guard.sh` 每次 up 先验 token 有效性再决定是否重签。

**Q：想换 50MB 上限？** 改 `configs/pre-receive` 顶部 `MAX_BYTES`，重跑 `up` 即可（hook 幂等覆盖）。
