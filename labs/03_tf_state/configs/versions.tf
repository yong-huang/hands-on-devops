# =============================================================================
# versions.tf — 远端 S3 后端（MinIO 冒充）
#
# 教学：state 从本地文件升级为远端对象存储后——
#   1. 任何人/任何 CI 都拿到同一份"真相"（不再各自为政）；
#   2. apply 时 TF 在后端创建锁对象（<key>.tflock），两个人同时 apply，
#      后到者报 "Error acquiring the state lock"——状态锁互斥；
#   3. state 里的敏感值依旧是明文（实验里当场 grep 给你看），
#      所以后端存储本身的访问控制很重要。
#
# S3 API 是事实标准，MinIO 全兼容——本实验零云依赖跑通"远端后端"。
# =============================================================================
terraform {
  required_version = ">= 1.6"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }

  backend "s3" {
    # TF 1.11+ 新写法：endpoint→endpoints.s3，force_path_style→use_path_style
    endpoints = { s3 = "http://localhost:9000" }
    bucket    = "tfstate"
    key       = "lab03/terraform.tfstate"

    # 锁开关：TF 1.10+ 用 S3 原生锁文件（<key>.tflock）替代 DynamoDB。
    # 不开它 = 完全没有锁检查！两个人同时 apply 后端不拦——这是隐形的大坑
    use_lockfile = true

    # MinIO 不是真 AWS：关掉 AWS 专属校验，再开 path-style 寻址
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
