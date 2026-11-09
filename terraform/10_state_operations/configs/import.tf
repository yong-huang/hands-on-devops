# =============================================================================
# import.tf — 纳管声明（TF 1.5+ import block）
#
# 与命令行 `terraform import` 的区别：
#   - import block 是配置的一部分：可 review、可进 PR、可批量，apply 时生效；
#     纳管完成后必须从配置里删掉（留着会在下次 plan 报"目标已纳管"）
#   - 命令行 import 是一次性手工操作：不进配置、不可 review，谁敲的只有
#     shell 历史记得。生产推荐 block。
#
# id 是"引擎侧的地址"：kreuzwerker 的 importer 只认完整 64 位容器 ID
# （容器名与 12 位短格式都会报 not found）——本文件由脚本动态生成。
# =============================================================================
import {
  to = docker_container.legacy
  id = "tf10-legacy"
}
