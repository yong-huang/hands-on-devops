# 04 · 集成点①：平台验收——第一个 MR 走通评审流

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 4 · 阶段一「入职第 1 周——把半导体内网立起来」收官
> webhook 事件观测 + dev1→MR→root 审批→合并的全自动评审流 + `acceptance.py` 九条断言一键自检
> 验收①②都在 `mr_gate.sh`：`up` 跑评审流并当场自检，`verify` 随时可重放九条断言

## Background

前三个实验各砌了一段墙：01 起平台、02 立权限与门禁、03 建载体。但「平台能用」和「平台能协作」是两回事——半导体设计流程的心脏是**评审**：RTL 改动必须经他人审过才能进 main（芯片流片后无法打补丁，评审是最后的堤坝）。

这个集成点做三件事：装一个**事件记录器**（webhook——GitLab 把事件 POST 到你指定 URL 的机制——的监听容器）让平台动作可观测。

再用真实用户走一遍 **MR 评审流**（作者 dev1 推分支开 MR，审批人 root approve 后 merge——GitLab 禁止作者自审，流程天然两权分立）。最后写 `acceptance.py` 把 01-04 的全部产出**一次性断言**，成为后续每个实验动手前的「平台体检」。

## What

心智模型一句话：**平台是一台机器，acceptance.py 是它的自检程序，webhook 是它的仪表盘**。

三个新组件各司其职：

| 组件 | 形态 | 作用 |
|:---|:---|:---|
| webhook-listener | python 容器（纯标准库，零 pip 依赖） | 记录每条 GitLab 事件到 `/data/events.json`（宿主 volume 直读） |
| mr_flow.py | python-gitlab + 真实 git push | dev1 身份推分支、开 MR；root 审批合并；断言 main HEAD 变更 |
| acceptance.py | python-gitlab + docker exec | 九条断言：组树/成员/双项目/保护分支/hook/LFS/webhook 注册/事件可达/MR 证据 |

验证方法：`./mr_gate.sh status` 看事件流与 webhook；`./mr_gate.sh verify` 九条全过打 `[ok]`。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 平台改造/升级前后确认没改坏 | 跑 `verify`——九条断言即回归测试（本系列约定：动手前先体检） |
| 想知道「某分支谁推的、MR 谁合的」 | 事件流按 kind/user/action 记账（push / merge_request + approved/merge） |
| CI 要感知仓库事件 | 生产中把监听器换成 CI 触发器——本实验的记录器就是它的打样（⚠️ 别在这里做成完整系统） |
| 审计「评审纪律是否被遵守」 | merged MR 的 approved_by 留痕即证据（断言 9） |

## Quick Start

前置：项目 1-3 完成（平台/组树/载体在位）、python-gitlab + pyyaml（02 前置已装）、Docker 网络 `semi-gitlab_default` 存在（01 compose 自建）。

```bash
./mr_gate.sh up      # 监听容器 + 注册 webhook + MR 评审流 + 九条断言（一条龙，约 2 分钟）
./mr_gate.sh verify  # 重放九条断言
./mr_gate.sh status  # 事件流 + webhook 清单
./mr_gate.sh clean   # 摘 webhook + 删监听容器（平台资产保留）
```

`up` 的评审流关键输出（2026-10-29 实测，节选）：

```
=====> [flow] 第一个 MR 评审流（dev1 推分支 -> 开 MR -> root 审批 -> 合并）
[  =] merge 前 main HEAD：4d39f5c6ebb3
[ok] dev1 推送分支 feature/hello-mr-1793294689（门禁放行）
[ok] dev1 开 MR !6（等 GitLab 计算 merge_status）
[ok] root 审批通过（POST /approve）
[ok] root 合并 MR !6
[ok] main HEAD 变更 4d39f5c6ebb3 -> 7f9c02d5c1f2
[ok] 审批留痕：root；MR 状态 merged
[ok] 第一个 MR 评审流全链路走通
```

`verify` 的真实输出（九条全过；事件计数会随重放累计）：

```
=====> [8/9] webhook 事件可达（push + merge_request 两类）
  [ok]   收到 11 条 push 事件（dev1 的分支推送）
  [ok]   收到 15 条 merge_request 事件（动作：['merge', 'open', 'update', 'approved', ...]）
=====> [9/9] MR 评审流证据（状态 merged + 审批留痕）
  [ok]   存在 3 个 merged MR（最近：!6）

[ok] 平台验收九条断言全过——01-04 产出全部在位
```

诚实预期：`up` 每次重放会新开一个 MR（greeting 文件带时间戳避免冲突）；GitLab 默认拒绝发往内网地址的 webhook，`up` 会自动放行管理员设置。

dev1 的 PAT（Personal Access Token，个人访问令牌）由 rails runner（容器内直跑 Rails 脚本的管理通道）签发存 `.dev1-token`（gitignore）；dev1 的 git 推送口令读自 `../02_org_guard/configs/org.yaml`。

## How It Works

### 评审流的身份设计：作者与审批人必须是两个人

dev1（Developer 30）有资格推分支、开 MR，但 main 的 merge_access=40 让它合不了；root（Owner）能审批能合并，但 GitLab 禁止 MR 作者审批自己。

于是「dev1 开、root 合」不是脚本凑巧，而是权限结构的必然——两权分立是用权限矩阵表达的，不是靠自觉。

### webhook 链路：同网络 DNS + 放行内网

监听容器挂在 `semi-gitlab_default`（01 的 compose 网络），GitLab 容器靠 Docker 内置 DNS 直连 `webhook-listener:9000`。

第一个坑：GitLab 默认**拒绝**保存发往内网地址的 webhook（422），要用管理员 API 打开 `allow_local_requests_from_web_hooks_and_services`（up 里幂等放行）。事件投递是异步的——断言事件可达前，flow 要真的产生过事件。

### python-gitlab 8.6 的 approve() 会"清空"对象

`mr.approve()` 用 GitLab 的响应**整体替换**对象 attrs，之后 `mr.iid` 变成 None，紧跟着的 `mr.merge()` 会打到 `/merge_requests/None/merge` 吃 404。

报错文案完全看不出原因（抓 debug 日志才见真凶）。修法：approve 之后**重新 get** 再 merge（`mr_flow.py` 已内置）。

同类坑：protectedbranches.list() 返回简化对象，级别在 `push_access_levels`（复数）列表里而不是 `push_access_level`。

### acceptance.py 的断言分层

九条断言按「结构 → 通道 → 证据」递进：1-4 查结构（组树/成员/项目/保护分支语义），5-7 查通道（Gitaly hook 可执行、LFS 存储体积、webhook 注册），8-9 查证据（事件真的到达过、merged MR + 审批留痕）。

结构在而通道断，说明配置没生效；通道在而证据断，说明流程没跑——三层定位法比一锅粥的 assert 快得多。

## Pitfalls & Q&A

**坑 1：webhook 注册 422。** GitLab 默认禁内网 webhook，up 里 `PUT /application/settings` 放行；探活用 `docker exec gitlab curl webhook-listener:9000/health` 验证 DNS 与连通。

**坑 2：merge 报 404/405 一头雾水。** 三种可能按序排查：`detailed_merge_status` 非 mergeable（如两分支各自新增同名文件的 add/add 冲突 → 405）、iid 变 None（approve() 坑 → 404）、MR 已被合掉（405）。

mr_flow.py 的异常分支会打印 detailed 状态。

**坑 3：MR 作者与 token 身份。** 用 root token 开的 MR 只能 root 合、没法走审批——作者身份跟着**签发 token 的用户**走，dev1 的 PAT（semi-dev1）是流程的一半，不是装饰。

**Q：为什么监听器用标准库不用 Flask？** 事件记录器只需要 POST 存档一个动作，省掉容器内 pip 依赖与镜像体积；未来真要换 CI 触发器时，接口（POST /hook）不变，实现随便换。

**Q：up 重放会污染 main 吗？** 每轮 merge 一个 `docs/mr_greeting_<ts>.md`，main 上会积累小文件——这是真实的平台历史；介意就 `../03_rtl_lfs/rtl_lfs.sh` 的 up 重放载体（会重置项目）。

**Q：九条断言里 LFS 为什么查容器 du 而不是 API？** 项目的 statistics 有缓存延迟（lfs_objects_size 可能 stale），容器内 `du` 是唯一不会说谎的数。

**Q：rtl-gcd 被 03 的 up 重置过，webhook 和 MR 全没了怎么办？** 这正是验收脚本的价值——实测发生过一次：03 重放载体导致项目重建（id 9→10），verify 当场抓住「webhook 缺失 + 无 merged MR」。

不需要手工修复，重跑 `./mr_gate.sh up` 即在新项目上重挂 webhook、重走评审流，九条断言恢复全绿。**acceptance.py + up 就是平台的「体检 + 自愈」组合。**
