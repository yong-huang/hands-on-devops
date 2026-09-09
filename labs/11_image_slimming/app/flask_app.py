# 依赖版应用：多阶段构建里 pip install 到独立 venv，运行层零构建工具
from flask import Flask

app = Flask(__name__)


@app.get("/healthz")
def healthz():
    return "app=flask-slim status=ok\n"


@app.get("/")
def root():
    return "hello from flask-slim\n"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
