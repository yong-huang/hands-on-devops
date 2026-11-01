# semi/01_gitlab_up · GitLab Omnibus 调优配置
# 挂载为容器内 /etc/gitlab/gitlab.rb（ro），`gitlab-ctl reconfigure` 每次读它生效。
# 端口归属：全系列分配表 28200-28279 段（根 README）。

## ── 对外地址 ─────────────────────────────────────────────────────────
## external_url 决定页面地址与 clone URL（http://localhost:28200/semi/...）。
## 宿主 28200 → 容器 80，所以 nginx 监听端口显式压回 80，别让它跟着 URL 走。
external_url 'http://localhost:28200'
nginx['listen_port'] = 80
nginx['listen_https'] = false          # 本实验只在 HTTP 层玩，TLS 是以后的事
## 宿主 28222 → 容器 22；SSH clone URL 里显示的端口
gitlab_rails['gitlab_shell_ssh_port'] = 28222

## ── 内存减配（容器限额 4.5GB，目标稳态 < 3.5GB）──────────────────────
## Puma worker 数：Omnibus 默认 = CPU 核数（本机 18 核 ≈ 每 worker ~1GB，
## 直接爆限额）。小内存部署的官方建议是 2-3；1 则退化为单进程模式。
puma['worker_processes'] = 2
## 单 worker RSS 超 1GB 自杀重启（防内存泄漏吃满限额的保险丝）
puma['per_worker_max_memory_mb'] = 1024
## Sidekiq 后台任务线程数：默认 20，压到 5（本实验没有重后台队列）
sidekiq['concurrency'] = 5
## 关闭 Prometheus 全家桶（prometheus + alertmanager + 全部 exporter），
## 一套下来省 ~1GB —— 可观测性在清单项目 24 用 API 拉数替代
prometheus_monitoring['enable'] = false

## ── Server hooks（02_org_guard 加装）：全局自定义钩子目录 ──────────────
## Gitaly 对每个仓库执行 push 时，会先跑 custom_hooks_dir 下的 pre-receive。
## 平台级 IP 保护：>50MB 的 blob 直推一律拒绝，逼大文件走 LFS（半导体内网纪律）。
gitaly['configuration'] = {
  hooks: {
    custom_hooks_dir: '/var/opt/gitlab/gitaly/custom_hooks',
  },
}

## ── Container Registry（06_eda_image 加装）────────────────────────────
## 宿主 28250 → 容器 5050；镜像版本即 CI 环境契约（eda-base:1.0）
registry_external_url 'http://localhost:28250'
registry['enable'] = true
registry_nginx['listen_port'] = 5050
registry_nginx['listen_https'] = false
