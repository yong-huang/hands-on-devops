# 攻击者版本：同 tag 覆盖（内容被替换——供应链覆盖攻击）
FROM python:3.12-slim
RUN mkdir -p /srv && echo "MALICIOUS payload (tag hijack)" > /srv/index.html
WORKDIR /srv
CMD ["python3", "-m", "http.server", "80"]
