# =============================================================================
# versions.tf — 本实验刻意用本地 state（无 backend 块）
#
# 教学：import block（1.5+）/ state mv / state rm 操作的都是"state 账本"，
#       与后端无关。用本地文件做这些操作，账本就躺在工作目录里
#       （terraform.tfstate + 每次变动自动留的 terraform.tfstate.backup），
#       每一步都看得见摸得着——先在明处学会，远端后端只是换个存放位置。
#
# 注意：本地 state 没有锁！本实验全部单人顺序操作，不存在并发风险；
#       多人协作场景请回到项目 08/09 的远端后端 + 锁。
# =============================================================================
terraform {
  # import block 配置生成（-generate-config-out）需要 TF 1.5+；
  # moved block 需要 TF 1.1+
  required_version = ">= 1.5"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0" # 与 08/09、lab 01-05 同版本：镜像源互通
    }
  }
}

provider "docker" {}
