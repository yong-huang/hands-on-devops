# 26 · 监控栈（Prometheus + Grafana）

> Prometheus 抓取 metrics → Grafana 可视化 → Node Exporter 提供主机指标。

## 快速开始
```bash
cd labs/26_monitoring_stack
./monitoring_stack.sh up
./monitoring_stack.sh down
```

Prometheus: http://localhost:9090 | Grafana: http://localhost:3001 (admin/admin)

## 深入要点
- Pull 模型：Prometheus 主动抓取，不做推送
- PromQL：`up`, `rate(node_cpu_seconds_total[5m])`, `histogram_quantile()`
- 四种指标类型：Counter / Gauge / Histogram / Summary
