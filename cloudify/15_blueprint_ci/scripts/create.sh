#!/usr/bin/env bash
# script 插件入口：operation inputs 以环境变量注入（who ← 蓝图 get_input）
set -euo pipefail

# ctx logger info：写进执行日志（install 输出里的 LOG <app> [...] INFO: 行）
ctx logger info "create.sh running for node=$(ctx node name), who=${who}"

# ctx instance runtime-properties <key> <value>：写运行期属性
#   解析期值用 get_property，运行期值用 get_attribute —— outputs 端读这个
ctx instance runtime-properties said "${who}-from-cloudify-local"
