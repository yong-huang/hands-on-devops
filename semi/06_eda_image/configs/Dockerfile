# eda-base:1.1 · EDA 标准执行镜像（1.0 + yowasp ice40 工具链：yosys/nextpnr/icepack 的 WASM 版）
# ubuntu:24.04 arm64 + apt 三件套（verilator/yosys/iverilog）+ pip cocotb 固定版本
# 全程国内源：apt 换清华、pip 走清华；镜像推 localhost:28250（GitLab Registry）
FROM docker.1ms.run/library/ubuntu:24.04

RUN sed -i 's|archive.ubuntu.com|mirrors.tuna.tsinghua.edu.cn|g; s|security.ubuntu.com|mirrors.tuna.tsinghua.edu.cn|g' \
        /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        verilator yosys iverilog python3-pip python3-dev build-essential make ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# cocotb 固定版本：环境契约的一部分（升级走新 tag，不许 latest 漂移）
RUN pip3 install --break-system-packages -i https://pypi.tuna.tsinghua.edu.cn/simple cocotb==2.1.0 \
    && pip3 install --break-system-packages -i https://pypi.tuna.tsinghua.edu.cn/simple \
        yowasp-yosys yowasp-nextpnr-ice40 yowasp-icestorm

COPY smoke-test.sh /usr/local/bin/smoke-test.sh
RUN chmod +x /usr/local/bin/smoke-test.sh
