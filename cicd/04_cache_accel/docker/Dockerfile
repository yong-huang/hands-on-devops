# 缓存实验用 Dockerfile——经典分层缓存模式：
# 依赖层（慢、cacheable）在前，源码层（快、常变）在后。
# 冷跑时依赖层要执行（sleep 模拟慢安装），热跑命中 Docker 层缓存直接跳过。
FROM alpine:3.19

# 模拟慢依赖安装（冷跑 6 秒，热跑命中缓存跳过）
COPY deps.lock /tmp/deps.lock
RUN sleep 6 && echo "deps installed from $(cat /tmp/deps.lock)" > /tmp/deps-done

# 模拟源码层（常变、始终重跑）
COPY src/ /tmp/src/
RUN echo "src files: $(ls /tmp/src/ | wc -l)" > /tmp/build-info

CMD ["cat", "/tmp/deps-done", "/tmp/build-info"]
