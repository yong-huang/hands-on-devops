# 12 · 版本账本与一键回滚

> 版本账本 = 每次 deploy / rollback 都在一个 JSON 文件里**追加**一条记录：
> 什么版本、落在哪个槽、用什么镜像、什么时候、谁干的、为什么。
> 回滚 = 查账本 + 流量指针回拨 + 账本再记一笔；对账 = 账本指针、容器
> 镜像/标签、线上实测响应三方必须一致。
>
> 本实验复用 09 的蓝绿双槽：v1→v2→v3 三次部署后一键回滚 v1，其中
> v2→v3→回滚→对账四步全程实测 2.7 秒。

## Background

09-11 的回滚都是"平台能力"：compose 拨指针、k8s 找 revision。但"线上现在
跑的到底是哪个版本、谁在什么时候换的、为什么换"这三个问题，平台没有给
一个权威答案——事故复盘的第一问往往靠猜。

账本把部署历史变成可查询的数据：出事时往前翻，改动链一目了然；回滚时
不用人脑回忆"上一个好版本是谁"，账本直接指路。

## What

**定义**：版本账本 = append-only 的部署事件流；一键回滚 = 账本指路 +
指针回拨 + 账本追加 rollback 记录；三方对账 = 账本、容器、线上实测
互相印证。槽 = 蓝/绿两套可独立替换的容器位置（09 已建，本实验复用）。

| 账本字段 | 例 | 回答的问题 |
|:---|:---|:---|
| `version` / `slot` / `image` | `v2` / `green` / `nginx:1.25-alpine` | 线上是谁、在哪个槽、用的什么镜像 |
| `ts` / `operator` | `2026-10-19T21:21:34+08:00` / `rollbook.sh` | 什么时候、谁干的 |
| `action` / `reason` | `rollback`（`from: v3`）/ 一键回滚演示 | 干了什么、为什么干 |

账本像航海日志：每次转向都追加一行，只写不改，出事往前翻就有完整轨迹。
失效边界：类比没覆盖"日志本身也可能与现实脱节"——只记账不核对，账本
写 v1、线上跑 v2 的漂移无从发现，所以配套的**三方对账**不是可选装饰，
而是账本可信的前提。

![版本账本与一键回滚](images/release_ledger.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/cicd/12_release_ledger/images/release_ledger.html)（或本地打开 [`images/release_ledger.html`](images/release_ledger.html)）。

看图方法：rollbook.sh 是唯一的写入口——向账本只追加记录、向空闲槽部署、
体检通过才拨 edge 的流量指针；recon 从账本读到容器再测线上，把三方串
起来对质。

## When to Use

- 裸 docker / 虚机发布（没有平台回滚能力）时的审计底座：账本即事实源；
- 多人/多环境交接：账本就是交接文档，"现在线上是什么"一查便知；
- 反例：k8s 环境（`rollout history` 已是权威）再手记账本 = 双份真相源，
  迟早漂移——有平台的以平台为准，账本补的是平台不管的"为什么"。

## Quick Start

前置：Docker、curl、python3（账本读写与计时）；nginx:1.25/1.27/1.29-alpine
三个版本镜像本地已有（离线可跑，首次拉取除外）。

```bash
cd cicd/12_release_ledger
./rollbook.sh                  # 全程：up → v2 → v3 → 回滚 v1 → 对账，断言 <60s
./rollbook.sh up               # 起网络 + 槽 + edge，部署 v1，账本立账
./rollbook.sh deploy v2        # 部署到空闲槽：体检 → 拨指针 → 记账
./rollbook.sh rollback v1      # 一键回滚：账本指路 → 拉起 → 回拨 → 记账
./rollbook.sh recon            # 三方对账：账本 ↔ 容器 ↔ 线上
./rollbook.sh clean            # 销毁环境
```

`deploy` / `rollback` 段的真机取证（完整输出见脚本运行日志）：

```
        [ok] 体检通过：green /version = v2
        [ok] 账本追加：deploy v2 @ green
        [ok] 体检通过：green /version = v1
        [ok] 账本追加：rollback v3 → v1 @ green（含版本/时间/原因）
```

`recon` 段与计时断言：

```
        [ok] 三方一致：账本最新记录 rollback v1 @ green（nginx:1.27-alpine）
        [ok] v2→v3→一键回滚→对账全程 2.7s（< 60s）
```

账本实物（4 笔记录，`rollback` 多一个 `from` 字段）：

```json
{
  "seq": 4,
  "ts": "2026-10-19T21:21:36+08:00",
  "action": "rollback",
  "version": "v1",
  "slot": "green",
  "image": "nginx:1.27-alpine",
  "operator": "rollbook.sh",
  "reason": "一键回滚演示（验收：<60s 全程）",
  "from": "v3"
}
```

诚实预期：2.7s 是本机（OrbStack）实测，复跑在几秒量级浮动；断言的不变式
是"全程 < 60s"与"三方一致"，不是这个具体数字。

## How It Works

### 部署四步不变式：体检 → 拨指针 → 才算部署

每次 `deploy` 都走同一条通道：新版本拉起在**空闲槽**、直连体检 `/version`、
通过才覆写 `active.conf` 并 reload edge、账本追加一笔。`rollback` 复用同一
通道——只是版本来自账本、多记一个 `from`。回滚不是独立机制，是"部署"
的一个特例。

### 三方对账：不信任任何单一真相源

`recon` 读账本最后一条记录，取其 `slot` 找到容器、`docker inspect` 出
`version` 标签与镜像 tag，再 curl 线上 `/version`——三者必须互相等。任何
一次"手工 docker 改了线上"或"账本忘了记"都会当场暴露。

### 指针回拨的耗时从哪来

`active.conf` 是 bind mount 进 edge 的单文件（`cat >` 原地覆写保 inode），
reload 是优雅换配置——单次部署/回滚只有"拉槽 + 体检 + reload"三个动作。
没有镜像构建、没有传输，槽位机制让旧版本随时可重新实例化，所以
v2→v3→回滚→对账四步合计才 2.7s。

## Pitfalls & Q&A

- **① nginx 启动即解析 upstream 主机名**：edge 先于槽容器启动会
  `host not found in upstream "slot-blue:80"` 直接 emerg 退出——compose
  里被启动时序侥幸掩盖，纯 docker 管理就暴露。槽先起、edge 后起，且
  reload 前检查 edge 存活、死了先 start 再 reload。
- **② `tr -d ':'` 会把端口冒号一起删掉**：从 `server slot-blue:80` 提取
  槽名得到 `blue80`，空闲槽判断永假——每次部署都原地替换现役槽，蓝绿
  悄悄退化成原地升级。用 `sed 's/:80$//'` 精确剥端口。
- **③ 体检循环里的裸 curl 会杀脚本**：容器重建瞬间连接被拒，curl 退出码
  56 在 `set -e` 下让整个脚本无声退出——重试循环内的 curl 必须跟 `|| true`。

Q&A：

- **账本和 k8s rollout history 什么关系？** history 记录"模板改了几版"，
  账本记录"谁在何时因何故切了流量"。有 k8s 的团队通常以 history 为技术
  真相、账本/工单为流程真相——本实验把两者合一是因为没有平台可依赖。
- **为什么回滚走部署同一条通道，而不是"把指针改回去"这么简单？** 因为
  旧版本的槽早已被后续部署复用，v1 此刻并不在线——回滚必须重新拉起 v1、
  体检、再拨指针。"改回去"只对旧槽还活着的情况成立，那是巧合不是机制。
- **对账多久跑一次？** 每次部署/回滚后立即跑（本实验已内置），生产里再加
  定时对账兜"手工改线上"的漂移——账本只能证明"记录过"，对账才证明"还在"。
