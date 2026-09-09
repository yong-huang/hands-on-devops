# =============================================================================
# .tflint.hcl — tflint 静态检查配置（实验 02）
#
# 教学：IaC 也要有"lint 关"——terraform validate 只查语法/引用，
# tflint 用规则集查"会踩坑的写法"（过时语法、声明未用、类型可疑等）。
# plugin 不写 version = 使用 tflint 内置的 ruleset.terraform，零网络依赖。
# =============================================================================
plugin "terraform" {
  enabled = true
}

# 必开的三条规则：老语法（${var.x} 插值）、命名规范、声明了没用到的变量
rule "terraform_deprecated_interpolation" { enabled = true }
rule "terraform_naming_convention"         { enabled = true }
rule "terraform_unused_required_providers" { enabled = true }
