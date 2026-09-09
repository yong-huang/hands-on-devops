#!/usr/bin/env bash
# =============================================================================
# tfrc.sh — Terraform provider 离线镜像环境（被各 TF 实验 source）
#
# 背景：provider 二进制托管在 GitHub Releases，部分网络环境不可达。
# 本仓库在 scripts/tf-mirror/ 内置了 filesystem mirror（kreuzwerker/docker），
# 本脚本生成 TF 配置指向它并导出 TF_CLI_CONFIG_FILE。
#
# 用法（实验脚本内）：
#   . "$(cd "$(dirname "$0")/../.." && pwd)/scripts/tfrc.sh"
#
# 新增 provider：把 zip 里的二进制放到
#   scripts/tf-mirror/registry.terraform.io/<ns>/<type>/<version>/<os>_<arch>/terraform-provider-<type>_v<version>
# =============================================================================
_hands_on_devops_tfrc() {
    local root cache
    # bash 里 $BASH_SOURCE 是被 source 的文件；zsh 的 `.` 不重绑 $0，
    # 因此再按"当前目录在 labs/NN_xxx 下"从 cwd 推断兜底
    root="$(cd "$(dirname "${BASH_SOURCE:-$0}")/.." && pwd)"
    if [ ! -d "$root/scripts/tf-mirror" ]; then
        root="$(cd ../../ && pwd)"
    fi
    cache="${TMPDIR:-/tmp}/hands-on-devops-tfrc.hcl"
    cat > "$cache" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "$root/scripts/tf-mirror"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF
    export TF_CLI_CONFIG_FILE="$cache"
}
_hands_on_devops_tfrc
