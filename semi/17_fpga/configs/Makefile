# gcd IP 的 iCE40HX8K 综合与布线
# 工具名可覆盖：CI 用 eda-base:1.1 的 yowasp（WASM），本地可用 brew native
# 例：make FREQ_MHZ=50（默认 yowasp-*）或 make YOSYS=yosys PNMR=nextpnr-ice40 ICEPACK=icepack
FREQ_MHZ ?= 50
YOSYS ?= yowasp-yosys
PNMR ?= yowasp-nextpnr-ice40
ICEPACK ?= yowasp-icepack

all: top.asc top.bin fmax.json

# 1) yosys 综合：RTL → ice40 网表
top.json: ../rtl/gcd.v
	$(YOSYS) -p "read_verilog ../rtl/gcd.v; synth_ice40 -top gcd -json top.json"

# 2) nextpnr 布线：网表 + 约束 → asc（布线结果）；fmax 从时序报告提取
top.asc: top.json gcd.pcf
	$(PNMR) --hx8k --package ct256 --json top.json --pcf gcd.pcf --asc top.asc \
	  --freq $(FREQ_MHZ) 2>&1 | tee pnr.log
	python3 extract_fmax.py pnr.log $(FREQ_MHZ) fmax.json

# 3) icepack：asc → bin（可烧写的比特流）
top.bin: top.asc
	$(ICEPACK) top.asc top.bin

.PHONY: all
