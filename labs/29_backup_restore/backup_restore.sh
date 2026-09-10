#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
step "backup" "备份清单"
note "1. Terraform state → S3 远端后端（实验 03）"
note "2. Gitea 数据卷 → docker run --rm -v ... tar czf backup.tar.gz"
note "3. Registry 存储 → 同上"
note "4. 数据库 → pg_dump/mysqldump"
note "恢复 = 反向操作 + 健康检查"
