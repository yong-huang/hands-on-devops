# 15 · 集成点② 手工发布流水线：make release 一条命令出厂即上线

> 构建在实验 11、仓库在 13、SBOM/签名在 14——能力齐了，但发布还是"分别到各目录敲命令"。
> 本实验把它们串成一条流水线：`make release VERSION=1.2.3` 走完构建→SBOM→签名→推送→
> 验签门→部署靶场→冒烟，并在 artifacts/ 留下一张可追溯清单。这就是实验 20 CI 化的蓝本。

## 1. 为什么需要它

把 11-14 的能力"串起来"这步，暴露的正是真实发布的问题：

- 步骤之间没有门：SBOM 没生成也能继续推、验签没跑也能部署；
- 产物没有关联：镜像、SBOM、签名散落各处，出事对不上号；
- 过程不可重复：手工顺序靠记忆。

流水线 = 步骤顺序化 + 门禁强制化 + 产物留痕化。

## 2. 总览：核心机制一图看懂

![release pipeline](images/release_pipeline.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/15_release_pipeline/images/release_pipeline.html)
> （或本地打开 [`images/release_pipeline.html`](images/release_pipeline.html)）。

看图方法：五个阶段从左到右，任何一步失败整条流水线失败。上行是制品流，下行是
证明流（SBOM/签名/验签门）；末列的追溯清单把 digest、SBOM 校验和、签名 tag、
部署时间绑在一张发布凭证上。

## 3. 快速开始

```bash
make lab-up                                  # 靶场提供 registry 与网络
cd labs/15_release_pipeline
./release_pipeline.sh release VERSION=1.2.3  # 或 make release VERSION=1.2.3
./release_pipeline.sh clean
```

真实输出（发布凭证 artifacts/release-1.2.3.txt）：

```
版本:        1.2.3
镜像:        localhost:5500/demo/webapp:1.2.3
镜像 digest: sha256:7d2b025ebde3...
SBOM 校验和: 9e26a396bfed...
签名 tag:    sha256-7d2b025e....sig
部署位置:    demo-webapp@devops-lab :28099
冒烟结果:    healthz 200 @ 2026-09-08 06:21:30
```

## 4. 核心概念

### 4.1 流水线的六步与三道内建门

| 步 | 动作 | 门 |
|:---|:---|:---|
| build | distroless 多阶段构建（实验 11） | 构建失败即停 |
| sbom | syft SPDX 清单（实验 14） | 生成失败即停 |
| push+sign | 推仓 + cosign 签名（13/14） | 推送失败即停 |
| gate | 部署前验签（cosign verify） | **非零即阻断** |
| deploy | 靶场网络启动 + healthz 冒烟 | 冒烟不过即回滚信号 |
| trace | 写发布凭证 | —— |

### 4.2 顺序敏感：签名必须在推送后

cosign 签名附着在 registry 的镜像 digest 上（`sha256-<digest>.sig` tag），
所以**先 push 后 sign**。这类顺序约束正是流水线存在的意义——脚本写对了，顺序
就不会错；靠人记忆，迟早翻车。

### 4.3 追溯清单：一次发布的全部证据

版本号、镜像 digest、SBOM 校验和、签名 tag、部署位置、冒烟时间——六行文本回答了
审计的全部问题："线上跑的是什么？哪次构建？谁签的名？什么时候上的？"
出事故时，这张表是根因分析（实验 28）与回滚（实验 29）的起点。

### 4.4 手工流水线是 CI 的雏形

`make release` 与 Jenkinsfile/workflow 的唯一区别是"谁来按回车"。实验 20 会把这
六步原样搬进 Gitea Actions——push 即发布，门禁一个不少。

## 5. Makefile 关键字段

```makefile
VERSION ?= dev                    # 默认值防呆：不传版本跑不了发布
release:
	./release_pipeline.sh release VERSION=$(VERSION) REG=$(REG)
verify-remote:                    # 任何人/任何机器都能独立复核签名
	COSIGN_PASSWORD="" cosign verify --key tmp/cosign.pub $(REG)/demo/webapp:$(VERSION)
```

坑清单：

- **坑① 先签后推**：cosign 签名要附着到 registry 内的 digest，顺序颠倒直接失败
  （签名语义要求"被签对象已存在"）；
- **坑② `$VAR）` 多字节粘尾**：bash 把全角括号吃进变量名（实验 06 坑⑤），所有
  变量后接非 ASCII 一律 `${VAR}` + 空格；
- **坑③ digest 的两种来源**：`docker inspect .RepoDigests` 只有 push 后才有——
  发布脚本要处理"本地还没有 RepoDigests"的时序。

## 6. 文件结构

```
15_release_pipeline/
├── README.md                 # 本教程
├── Makefile                  # release / verify-remote / clean 入口
├── release_pipeline.sh       # 六步流水线本体
├── app/app.py                # 业务代码（与实验 11 同源）
├── Dockerfile                # distroless 多阶段
├── artifacts/                # SBOM + 发布凭证（gitignore）
├── tmp/                      # 签名密钥对（gitignore）
└── images/                   # 图三件套（json/html/svg）
```

## 7. 深入要点

- **发布流水线的最小要素？** 原子步骤、失败即停、产物留痕、门禁强制。
  四者缺一，"能跑的脚本"就不是流水线。
- **部署前为什么要验签？** registry 里的镜像可能被覆盖/回退（供应链攻击面），
  验签把"信任 registry"降级为"信任签名私钥的持有者"。
- **追溯清单应该含什么？** 版本、digest、SBOM 校验和、签名信息、部署环境、
  冒烟结果与时间戳——事后审计与回滚的完整依据。
- **手工流水线如何演进为 CI？** 步骤不变、触发器换事件（git push）、执行者换
  runner、凭据换平台注入（实验 16-20 全程演示）。

## 8. 总结

阶段三收官：11 瘦身、12 Packer、13 Registry 治理、14 SBOM+签名、15 手工流水线——
交付物的"工程化"完成。第四阶段把手工的回车交给 CI：Jenkins（16-17）、
Gitea Actions（18）、Woodpecker（19），最终在实验 20 定型完整 CI/CD。
