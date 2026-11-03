# 27 · 集中日志：Loki × Promtail × ruler 告警

> CI 作业日志 → Promtail 抓取（带标签）→ Loki 存储 → LogQL 查询（行数/ERROR 计数/速率）→ ruler 告警（ERROR 速率>0）→ Alertmanager → webhook 真实送达。

## Background

可观测性第二支柱 logs。日志集中存储的价值：不用 `docker logs` 逐个容器翻，LogQL 一条查询统计任意时间窗的 ERROR 速率，且能直接当**告警表达式**（日志即指标）。本实验六件栈全本地：Loki 3.1（tsdb/filesystem 单机）+ Promtail（抓共享 volume 的日志文件）+ 日志生成器（模拟 CI 作业）+ Grafana + Alertmanager + webhook 接收器。

## What

- `loki-config.yml`：单机（monolithic）+ filesystem 存储 + **ruler**（local storage：规则挂 `/loki/rules/fake/<ns>.yml`）
- `promtail.yml`：static_configs 抓 `/var/log/ci/*.log`，打 `job=ci, app=ci` 标签
- `configs/generator.py`：2s/行 INFO，每 5 行一条 ERROR（确定性错误密度）
- `loki_logging.sh` 五相：up / query（行数≥10、ERROR≥2 轮询、rate 查询）/ alert（AM 收到 + webhook 载荷断言）/ grafana（provisioning + 代理查询）/ down

## When to Use

- CI 作业日志集中查询与错误率趋势（"最近 1h ERROR 速率翻倍"）
- 日志驱动告警：ERROR 出现即通知（比"作业失败才通知"更早发现前兆）
- Grafana Explore 交互式查询（datasource 已 provisioning）

## Quick Start

```bash
cd labs/27_loki_logging
./loki_logging.sh all      # 五相断言，两遍全绿
./loki_logging.sh up       # 只起栈，手玩 LogQL：
#   logcli 不需要——curl 'http://localhost:29200/loki/api/v1/query_range?query={app="ci"}'
#   Grafana http://localhost:29201 (admin/admin)
./loki_logging.sh down
```

## How It Works

### 日志流的完整链路

生成器每 2s 写一行到共享 volume → Promtail 按 `__path__` 抓文件、追加标签、推 Loki（`/loki/api/v1/push`）→ tsdb 索引 + filesystem 块存储。LogQL 三种用法实测：行过滤（`{app="ci"} |= "ERROR"`）、计数（`count_over_time(... [5m])`）、速率（`rate(... [1m])`）。

### 日志驱动告警（ruler）

规则挂 `/loki/rules/fake/ci-alerts.yml`（local storage 强制 `fake/` 子目录）：

```yaml
expr: sum(count_over_time({app="ci"} |= "ERROR" [1m])) > 0
```

ruler 默认 **60s 评估一次**；触发后经 `alertmanager_url` 推 AM → 路由 webhook。

## Pitfalls & Q&A

1. **AM 版本是硬约束**：Loki 3.1 的 ruler **没有 `enable_api_v2` 字段**（配置 unmarshal 直接报错），默认打 AM 的 **v1 API**——而 alertmanager **v0.27 已移除 v1**（`410 Gone`，notifier 每轮报 `Error sending alert`）。AM 钉 **v0.25.0**（保留 v1）即通。告警送不到 AM 时先查这一对版本组合。
2. **bind mount 的内容变化不触发 compose recreate**：改完 loki-config 后 `docker compose up -d loki` 不会重建容器（检测不到挂载文件变化）——必须 `--force-recreate`。
3. **`/loki/api/v1/rules` 在 local storage 模式返回规则文件原文（YAML）而非 JSON**——别在它的响应上写 JSON 断言；ruler 状态的权威证据用下游（AM alerts + webhook 载荷）+ loki 日志旁证（"Starting rule manager" / "executing query"）。
4. **ruler 默认评估间隔 60s**：告警相的等待窗口按分钟计，别用 30s 超时。
5. **时序竞态**：ERROR 每 10s 一条、promtail 抓取有周期——query 相对 ERROR 计数断言要轮询（`≥2` 等待），首查常只有 1 条。
6. 日志生成器的 flush：python 写文件必须逐行 flush，否则 promtail 永远抓不到（缓冲不会自动刷）。

## 产物清单

- `docker-compose.yml`（六件栈，AM 钉 v0.25.0）/ `loki-config.yml` / `loki-rules/fake/ci-alerts.yml` / `promtail.yml`
- `configs/{generator.py,alertmanager.yml,webhook_receiver.py,grafana/provisioning/datasources/loki.yml}`
- `loki_logging.sh`：五相 7 断言全绿（两遍）；tmp/（日志/positions/接收器记录，clean 清）
