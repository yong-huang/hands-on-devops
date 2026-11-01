# 16 · 回归仪表盘：让质量趋势可见

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 16 · 阶段四「回归农场」收官
> 采集真实回归历史（基线/注错/最新）→ 纯静态 SVG 趋势站 → nginx 容器（:28210）承载
> 验收在 `dashboard.sh verify`：HTTP 200 + SVG 折线 / 数据与最新快照一致，全过打 `[ok]`

## Background

回归农场跑出了 15/16，但"趋势"分散在每条流水线的 artifact 里没人看。仪表盘把历史快照聚合成一张静态页：通过率折线、失败种子分布、快照明细表。它没有后端、没有 JS 框架——纯 Python 渲染 HTML+SVG，nginx 只当文件服务器——**部署层足够薄，数据层才是重点**。

降级说明（清单预案）：GitLab Pages 的 Omnibus 配置链（pages_external_url + 独立端口 + access control）探活成本高，本实验用旁挂 nginx 容器承载同一静态站——渲染与部署解耦，换 Pages 只改部署层。

## What

心智模型一句话：**summary.json 是账本，仪表盘是把账本贴墙上**。

| 组件 | 说明 |
|:---|:---|
| history/snap_*.json | 真实快照：P12 基线、seed7 注错、main 最新 aggregate（API 采集） |
| tools/render_dashboard.py | 快照 → HTML+SVG（passed 绿线 / failed 红线 / 失败种子表） |
| reg-dashboard 容器（:28210） | nginx:alpine 只读挂载 dashboard/ |

验证方法：`./dashboard.sh verify`（HTTP+元素 / 数据一致性两条）。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 团队看回归趋势 | 静态站（本实验）——零依赖、渲染快照即可 |
| 要交互（下钻到种子） | 快照 JSON + 前端框架——渲染层升级，数据层不变 |
| CI 自动更新 | 每条流水线末尾跑 render+部署（collect→render→rsync 三步） |

## Quick Start

前置：项目 12 完成（真实回归历史在 API 里）。

```bash
./dashboard.sh up       # nginx 上线 + 采集 3 份真实快照 + 渲染部署
./dashboard.sh verify   # 两条断言
./dashboard.sh status   # 快照数
./dashboard.sh clean    # 删容器（dashboard/ 保留）
```

`verify` 的真实输出（实测，全过）：

```
=====> [verify1] HTTP 200 + 页面含趋势元素
  [ok]   站点 200 且含 SVG 折线与历史表
=====> [verify2] 数据一致性：页面数据 == 最新快照
  [ok]   页面 passed=16/16 与最新快照一致

[ok] 项目 16 全部验收断言通过
```

## How It Works

### 快照采集：只采真数据

history 的三份快照来自 GitLab API：pipeline 146（P12 基线 aggregate）、148（seed7 注错的子 job summary 推导失败形态）、main 最新成功流水线的 aggregate。

**仪表盘的公信力来自数据源**——手造数据能过渲染但过不了"数据一致性"断言（verify②拿页面数字对最新快照）。

### 渲染与部署解耦

render_dashboard.py 只认 history/ 与 summary.json（文件协议）；nginx 只认 dashboard/ 目录（文件协议）。两个"只认文件"的组件怎么拼都行——Pages、对象存储、任何静态服务器。

## Pitfalls & Q&A

**Q：为什么 baseline146 快照可能缺失？** aggregate artifact 受 expire_in 限制（P12 设了 7 day）——过期即 404。采集脚本对缺失快照自然跳过（历史不完整但站照常渲染），生产上要拉长保留期或定期归档。

**Q：SVG 为什么不用图表库？** 两条折线的场景，手算坐标的内联 SVG 零依赖且离线可用——组件选型跟着复杂度走。

**Q：如何加新指标（如平均时长）？** 快照里加字段 + render 加一条 polyline——数据协议先于展示。
