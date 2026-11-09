# =============================================================================
# versions.tf — 远端 S3 后端（自家 ObjStor 冒充）+ use_lockfile 原生锁
#
# 教学：项目 08 的 pg 后端里，锁是"会话"——进程死连接断，锁自动回收。
#       本实验换成 S3 后端 + use_lockfile（TF 1.10+ 原生锁）：锁变成了
#       对象存储里的一个普通对象（<key>.tflock）。锁是数据之后，
#       "持锁者死亡"就不再自动解锁——对象还躺在桶里，下一个 apply 照样被拒。
#       这正是 S3 系后端与 pg 系后端最核心的行为差异（也是事故处理流程
#       完全不同的原因），两个实验连跑一遍就再也忘不掉。
#
# S3 API 是事实标准，自家 ObjStor（Rust S3 兼容存储）全兼容——本实验
# 零云依赖跑通"远端后端 + 锁对象可见 + 滞留强解 + 重启远程性"。
# =============================================================================
terraform {
  required_version = ">= 1.11" # use_lockfile 需 1.10+；endpoints.s3 新写法需 1.11+

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0" # 与 08/lab 01-05 同版本：镜像源互通
    }
    time = {
      source  = "hashicorp/time"
      version = "0.13.1" # time_sleep：人为拉长持锁窗口的道具
    }
  }

  backend "s3" {
    # TF 1.11+ 新写法：endpoint→endpoints.s3（ObjStor S3 API 在宿主 9200）
    endpoints = { s3 = "http://localhost:9200" }
    bucket    = "tfstate"
    key       = "lab09/terraform.tfstate"

    # 锁开关：TF 1.10+ 用 S3 原生锁对象（<key>.tflock）替代 DynamoDB 表。
    # 不开它 = 完全没有锁检查！两个人同时 apply 后端不拦——隐形的大坑
    use_lockfile = true

    # ObjStor 不是真 AWS：关掉 AWS 专属校验，再开 path-style 寻址
    access_key                  = "minioadmin"
    secret_key                  = "minioadmin"
    region                      = "us-east-1"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    use_path_style              = true

    # 锁等待不在此配置：用命令行 -lock-timeout=5s 控制（backend 不支持该参数）
  }
}

provider "docker" {}
