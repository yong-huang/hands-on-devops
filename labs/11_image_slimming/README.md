# 11 · 镜像瘦身与多架构：同一应用的四种出厂形态

> `python:3.12` 基础镜像 + 单阶段构建，一个"hello world"就是 386MB——把编译器、包管理器、
> 全部系统工具带上了生产线。本实验用同一段业务代码做三版 Dockerfile，实测 386MB → 50MB →
> 18MB（-95%），再用 buildx 一次产出 amd64+arm64 双架构镜像推进靶场私有 registry。

## 1. 为什么需要它

镜像不是越全能越好：

- **体积即带宽**：CI 每次 pull/push 都在付利息，386MB × 每日百次构建 = 什么都慢；
- **体积即攻击面**：镜像里多一个 shell、一个包管理器，攻击者就多一件武器；
- **单架构分发**：arm64 的 M 系列 Mac / 云主机，拉 amd64 镜像靠模拟，性能腰斩。

瘦身三板斧：多阶段构建（构建层不进运行层）、精简基础镜像（slim/alpine/distroless）、
`.dockerignore`（构建上下文瘦身）。

## 2. 总览：核心机制一图看懂

![image slimming](images/image_slimming.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/11_image_slimming/images/image_slimming.html)
> （或本地打开 [`images/image_slimming.html`](images/image_slimming.html)）。

看图方法：左边同一段业务代码出发的三条打包纪律，体积逐级递减；右边 buildx 双架构
推进靶场 registry 后，任意架构的机器都能 pull 到正确平台。

## 3. 快速开始

```bash
cd labs/11_image_slimming
./image_slimming.sh            # sizes → run → dive → multiarch → clean
./image_slimming.sh sizes      # 只构建三版并出体积对比表
./image_slimming.sh multiarch  # 只做多架构构建推送
```

真实输出（本机实测）：

```
=====> [sizes] 体积对比表
        版本              体积
        full             386MB
        multistage        50MB
        distroless        18MB
        结论：多阶段/精简基础镜像能砍掉 80%+ 体积

=====> [run] 三版逐一 HTTP 冒烟
        full :28101 → app=flask-slim status=ok
        multistage :28102 → app=flask-slim status=ok
        distroless :28103 → app=slim-demo status=ok
```

## 4. 核心概念

### 4.1 多阶段构建：构建层随便脏，运行层必须干净

```dockerfile
FROM python:3.12 AS build          # 构建层：pip/缓存/编译器随便用
RUN python -m venv /opt/venv
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim              # 运行层：只有解释器和代码
COPY --from=build /opt/venv /opt/venv
```

`COPY --from` 是一道单向闸门：只有你明确搬运的东西才进最终镜像。386MB→50MB 的
主要贡献者。

### 4.2 distroless：连 shell 都不留

`gcr.io/distroless/python3-debian12` 里没有 sh、没有 apt、没有 ls——攻击者即使
RCE 也两手空空。代价：`docker exec` 调试不可用，排障要靠日志与临时 sidecar。
18MB 的体积是"最小权限"思想在镜像上的投影。

### 4.3 dive：瘦身有证据，不靠感觉

`dive slim:full --ci` 逐层统计浪费（复制的临时文件、缓存、被后续层删除的大文件），
并给出 PASS/FAIL 效率判定——可直接进 CI 当阈值门（本实验真实输出 `Result:PASS
[Passed:2] [Skipped:1]`）。

### 4.4 buildx 多架构：一次构建，任意机器运行

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -f Dockerfile.distroless \
  -t localhost:5500/slim/multiarch:1.0.0 \
  --push .
```

registry 里存的不再是单个 manifest，而是 manifest list（按平台索引）。真实验收：
`curl /v2/_catalog` 出现 `slim/multiarch`，manifest 里列出 amd64 与 arm64 两个平台。

## 5. Dockerfile 关键字段

```dockerfile
FROM python:3.12-slim                 # 基础镜像的取舍决定体积下限
ENV PATH="/opt/venv/bin:$PATH"        # venv 搬运后改 PATH，替代"全局装"
EXPOSE 8080                           # 文档性声明，不产生端口映射
CMD ["python", "flask_app.py"]        # exec 形式：PID 1 是 python 而不是 sh
```

坑清单：

- **坑① `--no-cache-dir`**：pip 装完不删缓存，每层白背几十 MB；
- **坑② 层的顺序即缓存策略**：先 COPY requirements 再装依赖再 COPY 代码——
  代码一改缓存全失效是新手最常见的慢构建原因；
- **坑③ distroless 没有 shell**：healthcheck/exec 形式的调试命令都会失败，
  排障用 sidecar 或 `docker debug`（Docker Desktop 扩展）；
- **坑④ attestation manifest**：buildx 推送的 manifest list 里可能多出
  `unknown` 平台条目（buildkit 证明文件），属预期不是错误。

## 6. 文件结构

```
11_image_slimming/
├── README.md                  # 本教程
├── image_slimming.sh          # sizes / run / dive / multiarch / clean
├── app/
│   ├── app.py                 # stdlib 版应用（distroless 用）
│   ├── flask_app.py           # flask 版应用（前两版用）
│   └── requirements.txt
├── Dockerfile.full            # 反面教材：单阶段全量
├── Dockerfile.multistage      # 推荐形态：venv 多阶段
├── Dockerfile.distroless      # 极致：distroless 运行层
└── images/                    # 图三件套（json/html/svg）
```

## 7. 深入要点

- **多阶段构建为什么能减小体积？** 构建工具链、缓存、中间产物只留在构建层；
  运行层经 `COPY --from` 只拿运行必需品。层是只读叠层，跨层"删除"不减小体积。
- **distroless 与 alpine 的取舍？** alpine 小但保留 shell/apk（可调试、可攻击）；
  distroless 更小且无 shell（musl 兼容性问题也没有），代价是排障方式改变。
- **多架构镜像的原理？** manifest list（OCI image index）按 platform 索引多个
  manifest；buildx 用 QEMU/binfmt 跨架构构建，registry 侧一个 tag 对多平台。
- **镜像瘦身的量化手段？** dive 逐层效率分析 + registry 存储对比 + CI 里对镜像
  大小设阈值（超 200MB 即失败）。
- **瘦身的极限与边界？** 基础镜像决定下限；再小就换语言/静态编译（scratch+go）。
  瘦身以"运行正确性"为前提，冒烟测试必须覆盖。

## 8. 总结

386MB→18MB 不是炫技：更快的分发、更小的攻击面、更便宜的存储。但"出厂形态"只是
交付物的开始——谁来批量标准化地造镜像（Packer，实验 12）、谁来托管治理（Registry
实验 13）、怎么证明它里面是什么且没被篡改（SBOM+签名，实验 14）。
