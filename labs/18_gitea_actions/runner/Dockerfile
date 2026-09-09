# host 模式 runner：作业直接跑在 runner 容器内（绕开 docker copy 的网络抖动）
FROM gitea/act_runner:latest
USER root
RUN apk add --no-cache python3 git
