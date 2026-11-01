# eda-base:1.1 = 1.0 + cosign（CI 发布签名用；静态二进制，无网络构建）
FROM localhost:28250/semi/eda-base:1.0
COPY cosign /usr/local/bin/cosign
RUN chmod +x /usr/local/bin/cosign && cosign version > /dev/null
