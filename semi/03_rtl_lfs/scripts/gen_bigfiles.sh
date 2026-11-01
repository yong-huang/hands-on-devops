#!/usr/bin/env bash
# 生成"历史遗留"假大文件（半导体 CI/CD 清单项目 3）：
#   pdk/fake_pdk.lib  640MB  —— 假 PDK liberty 库
#   gds/fake.gds      960MB  —— 假 GDSII 版图
#   waves/wave.vcd    480MB  —— 假仿真波形
# 体积取 ~2GB 是刻意的：本机 localhost 传输近内存速度（实测 ~470MB/s），
# 小负载全量 clone 和 skip-clone 拉不开 5x 差距（260MB 实测 1.9x、1GB 实测 3.8x），
# 2GB 让 LFS 传输占主导，比值才有分辨力
# 内容 = 一行文本头 + /dev/urandom：体积真实、内容无意义，只作 LFS 演练负载
set -euo pipefail
dest="${1:?用法: gen_bigfiles.sh <仓库根目录>}"

gen() {
    local path="$1" mb="$2" label="$3"
    { echo "# SYNTHETIC ${label} —— 清单项目 3 生成的演练负载，非真实工艺数据"
      dd if=/dev/urandom bs=1048576 count="$mb" 2>/dev/null
    } > "$path"
}

mkdir -p "$dest/pdk" "$dest/gds" "$dest/waves"
gen "$dest/pdk/fake_pdk.lib"  640 "fake PDK liberty"
gen "$dest/gds/fake.gds"      960 "fake GDSII"
gen "$dest/waves/wave.vcd"    480 "fake VCD waveform"
ls -lh "$dest/pdk/fake_pdk.lib" "$dest/gds/fake.gds" "$dest/waves/wave.vcd" | awk '{print "  ", $9, $5}'
