# 27 · 集中日志（Loki + Promtail）

> Promtail 收集容器日志 → Loki 存储 + 索引 → LogQL 查询。

## 快速开始
```bash
cd labs/27_loki_logging
./loki_logging.sh up
./loki_logging.sh down
```

Loki: http://localhost:3100/ready

## 面试要点
- Loki vs ELK：Loki 只索引标签（不索引全文），存储成本低一个量级
- LogQL：`{container="nginx"} |= "error" | json | line_format "{{.msg}}"`
