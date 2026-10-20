# 16 · 🏁 终极串联——生产级发布系统

> 一条 commit 走完发布全链路，每道门可独立断言：PR 检查绿（act 本地 +
> 远端双验证）→ 合入 main → staging 自动部署（账本记录）→ prod 金丝雀
> 卡 environment 审批 → 放行后 10%→100% 晋级 → `/version`=v2；最后从
> gh api 提取 DORA 四指标 JSON，数值与本次演练一一对账。
>
> 这是 06 审批门、10 金丝雀、12 账本、15 语义化发布的合奏——每件乐器
> 都单独调过音，这里只负责指挥。

## Background

单点能力不等于系统能力：审批门会放行、金丝雀会灰度、账本会记账，拼在
一起时暴露的全是缝——部署记录和 workflow 互相踩（409 自阻塞）、审批
API 面与文档不符（404）、遗留流水线污染合并状态。串联实验的价值就是把
这些缝一个个踩出来并给出工程化解法。

trunk-based 是这条链的骨架：短分支、PR 必需检查、合入即部署 staging、
prod 走审批 + 金丝雀。发布节奏由主干决定，而不是由发布火车决定。

## What

**定义**：生产级发布系统 = 四道门的串联，每道门都有机器可验证的断言，
且失败演练被真实计入度量（不粉饰的指标才有意义）。

| 门 | 触发 | 断言 | 实测 |
|:---|:---|:---|:---|
| PR 检查 | pull_request | act 本地绿 + 远端 check-run success | `[pr] tests ok for v2` |
| staging | push→main | run success + deployment 记录 + 槽升版 | 账本 seq 2：staging v2 |
| prod 审批 | workflow_dispatch | run 卡 waiting → 放行才执行 | environment: production |
| 金丝雀 | 审批后 | 10% 采样混合 → 全量 100% | 60 采样 54/6 → 30/30 v2 |

发布链像机场塔台：飞机（commit）滑行（PR 检查）、起飞许可（合入）、
落地 staging（自动）、升巡航层要机长签放（prod 审批），升层过程逐级
切换（金丝雀）——塔台记录（账本 + deployments）全程留痕。

失效边界：类比没覆盖"塔台电台换频段"——审批的 REST 端点在 API 面更新
后 404，放行动作只能走环境的管理员通道（见 Pitfalls ②），链路因此多
了一次诚实的绕行记录。

![生产级发布系统](images/chain.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/16_production_chain/images/chain.html)（或本地打开 [`images/chain.html`](images/chain.html)）。

看图方法：上行是合入前（PR 门 → 合入 → staging），下行是合入后（prod
审批门 → 金丝雀 → 账本）；merge→prod 的虚线表示晋级由同一合入触发但
必须过审批，不是自动的。

## When to Use

- 把单点实验（审批/金丝雀/账本/语义化发布）拼成可断言的发布主干时；
- 团队从"手工点发布"迁移到 trunk-based 前的彩排：每道门先在玩具仓库
  走通，断言脚本即迁移验收单；
- 反例：门还没单点验证过就串联——缝会以复合形式出现（本实验的 409 就
  是单点实验从未覆盖的缝）。

## Quick Start

前置：Docker、act、gh（已认证）+ python3（账本与指标都靠它）+ 你有
推送权限且是环境管理员的真仓库（脚本顶部 `OWNER`/`REPO`——prod 段的
放行通道要改 environment 保护规则，需要 admin）。

```bash
cd cicd/16_production_chain
./release_chain.sh                # 全链路（约 15-20 分钟，含多轮远端 run 与审批放行）
./release_chain.sh setup          # 克隆 + 推 workflow + 槽位基建 + staging 基线
./release_chain.sh pr             # 开 PR：act 本地检查 + 远端检查 + 合入
./release_chain.sh merge-staging  # 等 staging run → 本地槽升版 + 账本
./release_chain.sh prod           # 触发 prod → 卡审批 → 放行 → 金丝雀
./release_chain.sh incident       # 失败演练：注入红 → 恢复（MTTR/CFR 取数）
./release_chain.sh metrics        # DORA 四指标 JSON + 对账断言
```

运行顺序有依赖：`incident` 复用 `prod` 清空的审批门，必须在 `prod` 之后、
`clean` 之前跑（clean 会把审批门复位）。

各段真机取证（完整输出见脚本运行日志）：

```
        [ok] act 本地跑通 pr-check（[pr] tests ok for v2）
        [ok] 远端 pr-check conclusion=success
        [ok] staging 槽 = v2，账本已记录（sha 49382ef）
        [ok] 金丝雀 10%：60 采样 v1 × 54 / v2 × 6（新版本灰度放量）
        [ok] 全量后 prod /version = v2（30/30）
        [ok] 失败 run conclusion=failure（deployment 7180614317 status=failure）
        [ok] 四指标字段完整，数值与本次演练对账一致
```

DORA 四指标（gh api 提取，JSON 全文见 `.logs/dora.json`）：

```
  deployment_frequency:  prod_deployments_total=3 (success 2 / failed 1)
  lead_time_for_changes: PR#1 merged → 首次 prod 成功部署 = 3826s
  change_failure_rate:   1/3 = 33.33%（失败演练真实计入）
  mttr:                  failure → recovery = 27965s（墙钟，含人工介入等待窗口）
```

诚实预期：lead time 与 MTTR 是**墙钟值**——含调试与人工等待，不是纯流水
时间；approval 无法被 REST 放行（两端点 404，06 的发现复现并升级），走
的是管理员通道。另：prod/clean 段脚本（评审修复后）未经真机全段复跑，
复现时若端点行为再变，以日志为准。

## How It Works

### 四道门的断言设计

每道门的断言都来自"机器可查的真相"：PR 门查 check-run conclusion，
staging 门查 run + 槽的 `/version` + 账本，prod 门查 waiting 与
deployment 记录，金丝雀门查加权采样分布。

失败演练的红不是模拟——broken run 真实失败、deployment 真实标 failure，
CFR/MTTR 才有据可依。

### deployment 记录为什么由编排器创建

workflow 里自建 deployment 会被**自己的 pending check-run** 卡 409
（auto_merge=false 也不豁免）。解法：交给 run 之外的编排器——run 绿、
combined success 后再经 gh api 建记录。

### 审批门的放行：管理员通道 + 取消重发

environment 审批把 run 卡在 waiting（断言 ✓），但放行的两个 REST 端点
都 404（后者新结构已无 id 字段——06 的发现复现且升级）。自动化走**管理
员通道**：清空 reviewers 再取消重发（waiting run 不重评规则，变更反而
会取消它）。

clean 段把 reviewer 规则复位——绕行用了通道，门要装回去。

### DORA 指标的去噪

environment job 会为每次 run 自动生成一条**无描述**的 deployment 行——
409 时代的失败尝试在指标里留下 18 条假"失败"。按"有描述 = 编排器主动
记录"过滤后，3 条真实发布事件才浮出水面。指标管道的第一课：先定义什么
算一次部署，再谈度量。

## Pitfalls & Q&A

- **① workflow 内自建 deployment 被 409 自阻塞**：run 自身的 check-run
  pending → combined status 永远到不了 success，`auto_merge=false` 不
  豁免。部署记录由 run 外的编排器在 combined=success 后创建。
- **② environment 审批无 REST 通道**：`approvals` 与
  `pending_deployments/{id}/approve` 均 404，且 pending 对象新结构已无
  id 字段。自动化放行 = update-environments 清空 reviewers（管理员
  通道）+ 取消重发；人工放行 = Web UI 点 approve。两者都如实记录。
- **③ waiting 中的 run 不重评保护规则**：删/改规则不解锁已 waiting 的
  run，保护规则变更还会直接取消它（conclusion=failure 且无日志）——
  唯一出路是取消重发。
- **④ api.github.com 与 github.com 独立抖动**：api 返回 200 而
  github.com 连接超时（git push 断）——连通性探测必须分域名，别用
  API 的绿灯误判 push 通道。

Q&A：

- **为什么 prod 门用 environment 而不是 branch protection？** 审批是
  "放行一次部署"的语义，挂在部署入口（environment）而非代码入口
  （branch）；branch protection 管的是"什么能进 main"，两者是不同层。
- **金丝雀 10% 的采样为什么是 54/6 而不是精确 54/6±0？** 加权轮询在
  长周期里趋近权重，60 个采样的方差完全正常——断言只要求"混合存在 +
  全量后 100%"，精确比例留给项目 10 的确定性发牌实验。
- **失败演练会永久污染指标吗？** 会，而且**应该**——CFR 的分子就是真实
  失败。治理动作（回滚/修复）把 MTTR 压下来才是指标存在的意义；把失败
  藏起来等于把仪表盘的红色灯泡拧掉。
