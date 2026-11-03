# CI 工具镜像：Gitea Actions job 容器（三道门的执行环境）
# 三件套均为单二进制，GitHub release 直装（网络抖动由构建脚本重试兜底）
FROM python:3.11-slim
# node：JS action（actions/checkout 等）的运行时；debian 源换 TUNA（实测 13s vs 官方 220s）
RUN sed -i 's#deb.debian.org#mirrors.tuna.tsinghua.edu.cn#g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update && apt-get install -y --no-install-recommends nodejs git \
    && rm -rf /var/lib/apt/lists/*

# 三件套由主脚本从官方工具镜像抽取后 COPY 进来（github release 直下会被截断）
COPY conftest /usr/local/bin/conftest
COPY trivy /usr/local/bin/trivy
COPY gitleaks /usr/local/bin/gitleaks
RUN chmod +x /usr/local/bin/conftest /usr/local/bin/trivy /usr/local/bin/gitleaks \
    && conftest --version && trivy --version && gitleaks --version
