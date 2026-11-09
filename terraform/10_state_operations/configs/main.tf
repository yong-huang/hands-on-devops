# =============================================================================
# main.tf — 基础资源：镜像 + 一台"存量"容器的纳管声明
#
# docker_container.legacy 的完整配置不在这里——本实验走 TF 1.5+ 的
# 配置生成路线：import block 只声明"纳管谁"，资源体由
# `terraform plan -generate-config-out=generated.tf` 按账本实况生成
# （生成文件里是引擎回读的全部属性，config == state，plan 天然收敛）。
# 手写配置 + import 的路线与坑见 README 的 Pitfalls。
# =============================================================================

resource "docker_image" "demo" {
  name = "alpine:3"
}
