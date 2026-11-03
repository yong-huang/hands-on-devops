# 26 · 监控栈：Prometheus × Grafana × Alertmanager 盯自己的 CI

> 六件栈（Prometheus / Grafana / node-exporter / pushgateway / Alertmanager / webhook 接收器）：CI 作业指标推入 → 三条曲线有数据 → 两条告警**真实触发**并经 Alertmanager **送达 webhook**。

## Background

可观测性三支柱中的 metrics 一柱，落到自己身上最有感：盯自己的流水线（构建次数/时长/成功率/队列积压）。CI 作业是短命进程，指标走 **pushgateway**（拉模型不适合短任务——push 到网关，Prometheus 再统一拉）。告警经 **Alertmanager** 路由到 webhook——本实验用 python 接收器记录载荷，实证"告警真实送达"而非只看规则状态。

## What

- `docker-compose.yml`：六件栈（钉版本 tag：prometheus v2.53 / grafana 11.1 / node-exporter v1.8.2 / pushgateway v1.9 / alertmanager v0.27 / python 接收器）
- `prometheus.yml`（4 个抓取目标 + rule_files + alerting）· `alerts.yml`（BuildFailureRateHigh / QueueBacklog，for: 0s 教学即时触发）
- `configs/grafana/provisioning/`（datasource + dashboard 自动导入）· `configs/webhook_receiver.py`（POST 记录到 /data/alerts.json）
- `monitoring_stack.sh` 六相：up / push-metrics（成功×3+失败×1+队列 2）/ curves（三条 query 断言）/ alert（firing + 送达 + 载荷三重断言）/ grafana（provisioning + 代理查询）/ down

## When to Use

- 给 CI/CD 平台补可观测层：失败率告警、队列积压告警直通 IM/webhook
- 学 Prometheus 的 pull 模型与短任务 push 模型的边界（pushgateway 是唯一例外）

## Quick Start

```bash
cd labs/26_monitoring_stack
./monitoring_stack.sh all     # 六相 12 断言（两遍全绿）
./monitoring_stack.sh up      # 只起栈，看 UI：
#   Grafana http://localhost:29101 (admin/admin) · Prometheus http://localhost:29190
#   Alertmanager http://localhost:29193 · Pushgateway http://localhost:29191
./monitoring_stack.sh down
```

## How It Works

### CI 指标的 push 链路

```bash
echo 'ci_builds_total{status="success"} 1' | curl --data-binary @- http://localhost:29191/metrics/job/demo/instance/build1
```

分组参数（`job/demo/instance/buildN`）成为指标的 job/instance 标签——Prometheus 抓 pushgateway 时默认 `honor_labels=false`，分组标签被改名为 `exported_job/exported_instance`（实测可见），避免与抓取标签冲突。告警表达式直接按 `status` 标签聚合。

### 告警真实送达的三重断言

`alerts.yml` 两条规则（for: 0s 立即触发）→ Prometheus 评估 firing → 推给 Alertmanager → 路由到 webhook → python 接收器落盘。脚本断言：① Prometheus `/api/v1/rules` 两规则 state=firing；② Alertmanager `/api/v2/alerts` 两条 active；③ 接收器 `/data/alerts.json` 的 alertname 集合完整。Grafana 侧用 **provisioning**（datasource + dashboard 文件自动导入，非手工 UI 操作），并经 `/api/datasources/proxy` 打通"面板→Prometheus"数据链路。

## Pitfalls & Q&A

1. **90xx 端口被占用**：宿主 mihomo（Clash）监听 9090，且根 README 端口表约定 90xx 归 hands-on-mlops——监控栈整体迁 **291xx**（29190/29101/29102/29191/29193/29194）。OrbStack 对端口冲突静默降级（容器 Up 但宿主 curl 打到的是 mihomo，返回 `{"hello":"mihomo"}`）——`curl /-/ready` 404 即此征兆。
2. **push 的指标有抓取延迟**：推送后要等 Prometheus 下一轮抓 pushgateway（5s 周期）才可查询——紧跟 push 的断言必须轮询等待。
3. **counter 只有一个样本时 `rate()` 不工作**：窗口内不足 2 点，表达式恒空 → 告警永不触发。教学场景用即时值 `sum(ci_builds_total{status="failure"}) > 0`（生产可 increase/rate）。
4. **cAdvisor 在 Docker Desktop/OrbStack 上受限**（设计文档如实记录）：容器级指标用应用级 metrics 替代——CI 指标走 pushgateway 是有意为之，不是绕路。
5. Grafana provisioning 文件**只读挂载**即可自动导入；面板 uid 固定（ci-pipeline-26）便于断言与外链。

## 产物清单

- `docker-compose.yml`（六件栈，钉版本）/ `prometheus.yml` / `alerts.yml` / `configs/{alertmanager.yml,webhook_receiver.py,grafana/provisioning/*,grafana/dashboards/ci-pipeline.json}`
- `monitoring_stack.sh`：六相 12 断言全绿（两遍）；tmp/ 接收器记录（clean 随 down -v 清）
