# =============================================================================
# versions.tf — 远端 PostgreSQL 后端：真·会话级状态锁
#
# 教学：lab 03 的 S3 后端锁是"锁文件"（<key>.tflock）——约定俗成的互斥，
#       理论上谁都能绕过它直接删锁文件。本实验把后端换成 PostgreSQL：
#       锁变成数据库内的 pg_advisory_lock（会话级咨询锁），互斥由数据库
#       亲自保证——持锁的数据库会话不结束，别人就是进不来。
#
# 这一换，三个面试高频场景都能亲手复现：
#   1. 两个人同时 apply → 后到者 "Error acquiring the state lock"；
#   2. 持锁进程被 SIGKILL → 连接断，数据库自动回收锁（对比 S3+DynamoDB
#      要手动 force-unlock，pg 后端天然少一种"锁卡死"事故）；
#   3. 持锁进程被 SIGSTOP（假死）→ 连接还在、锁还在 → 只能 DBA 式强解
#      （pg_terminate_backend 干掉持有者的连接）。
#
# 后端连接串走宿主 15432（容器内 5432）：154xx 是本实验一次性专用段。
# =============================================================================
terraform {
  required_version = ">= 1.6"

  backend "pg" {
    # sslmode=disable：本机回环演示，不起 TLS（生产务必 verify-full）
    conn_str = "postgres://terraform:terraform@localhost:15432/terraform_state?sslmode=disable"
  }

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0" # 与 lab 01-05 同版本：插件缓存互通，不用重复下载
    }
    time = {
      source  = "hashicorp/time"
      version = "0.13.1" # time_sleep：把"持锁窗口"拉长到秒级，并发演示的道具
    }
  }
}

provider "docker" {}
