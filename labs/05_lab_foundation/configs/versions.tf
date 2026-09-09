# =============================================================================
# versions.tf — 靶场环境（labs/05）：后续 25 个实验的被管对象都在这里声明
#
# 靶场四件套：
#   lab-nginx    目标应用（部署/漂移/监控的"业务"）
#   lab-registry 私有镜像仓（实验 12-15 的制品库）
#   lab-minio    S3 兼容存储（实验 3 的 state 后端、实验 29 的备份目标）
#   lab-gitea    Git 服务（实验 18/20 的代码源、实验 21 的 GitOps 源）
# =============================================================================
terraform {
  required_version = ">= 1.6"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}
provider "docker" {}
