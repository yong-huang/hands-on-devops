# =============================================================================
# 版本三 · distroless：没有 shell、没有包管理器、没有 libc 之外的系统
#   - 攻击面最小（没有 shell 给攻击者用）
#   - 体积最小；代价：没法 docker exec 进去调试
#   - python3-debian12 自带 /usr/bin/python3 入口
# =============================================================================
FROM gcr.io/distroless/python3-debian12:latest
WORKDIR /app
COPY app/app.py .
EXPOSE 8080
CMD ["app.py"]
