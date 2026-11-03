# 干净应用镜像（CI 应构建并推 registry 的"可信版本"）
FROM python:3.12-slim
RUN mkdir -p /srv && echo "original image payload" > /srv/index.html
WORKDIR /srv
CMD ["python3", "-m", "http.server", "80"]
