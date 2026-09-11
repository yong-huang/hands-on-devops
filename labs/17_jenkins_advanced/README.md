# 17 · Jenkins 深水区：并行、凭据与共享库

> 单条流水线串行跑是 Jenkins 最朴素的用法。工程化要三件事：**并行**压时间（构建与扫描
> 同时跑）、**凭据**管密码（密码进日志=事故）、**共享库**抽公共逻辑（两个 Jenkinsfile
> 复用同一段 Groovy）。本实验在一个 Jenkins 实例里三件全做，外加一个"明文泄漏"反面教材。

## 1. 为什么需要它

实验 16 的流水线是"一条直线"：build 等完 test 才开始。真实世界的发布：

- 镜像构建与安全扫描互不依赖——并行能省一半时间；
- 推送镜像要 registry 密码——`sh 'echo pass'` 一次就永久泄漏；
- 三个流水线都要"构建+推送+冒烟"——复制三份 Jenkinsfile 迟早分叉。

## 2. 总览：核心机制一图看懂

![jenkins advanced](images/jenkins_advanced.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/17_jenkins_advanced/images/jenkins_advanced.html)
> （或本地打开 [`images/jenkins_advanced.html`](images/jenkins_advanced.html)）。

看图方法：种子脚本启动即创建任务、凭据与共享库；deep-release 流水线并发跑两个分支、
经 withCredentials 掩码输出；右下的硬编码反面教材把明文写进日志，与打码路径形成对照。

## 3. 快速开始

```bash
cd labs/17_jenkins_advanced
./jenkins_advanced.sh            # apply（并行+凭据+共享库）→ leak（反面）→ clean
```

真实输出（关键节点）：

```
=====> [apply] 构建：并行 stage 计时 + 凭据打码 + 共享库
        构建 #1 结果: SUCCESS
        parallel 阶段耗时: 73ms（两个 sleep 4 串行应为 8s+）
        hello from shared library, jenkins-17!
        [ok] 日志中无明文凭据（withCredentials 打码生效）
=====> [leak] 反面教材：硬编码明文
        [x] 泄漏证据: password is supersecret123
```

## 4. 核心概念

### 4.1 parallel：两个分支同时开跑

```groovy
stage('parallel') {
    parallel {
        stage('build') { steps { sh 'sleep 4; echo build done' } }
        stage('scan')  { steps { sh 'sleep 4; echo scan done' } }
    }
}
```

前置条件：executor ≥ 2（种子脚本设了 4）。wfapi 的 parallel 阶段耗时 73ms 记录的是
"分支调度墙钟"，两分支各 4s 只花了一份——串行世界 8s 的活并行 4s 干完。

### 4.2 credentials：密码只活在内存里

```groovy
withCredentials([string(credentialsId: 'registry-pass', variable: 'REG_PASS')]) {
    sh 'set +x; echo "pushing with password (masked in log)"'
}
```

- 凭据存 Jenkins 凭据存储（本实验经 HTTP API 创建）；
- withCredentials 绑定的变量在日志里**自动打码为 \*\*\*\***；
- 反面教材：`sh 'echo "password is supersecret123"'` 明文进日志——grep 即泄漏。

本镜像组合的坑：credentials 插件 1511+ 已**移除** `StringCredentialsImpl`（老教程全灭），
改用 `org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl`（plain-credentials
插件），`withCredentials([string(...)])` 照常工作。

### 4.3 Shared Library：公共逻辑一处定义

vars/hello.groovy（git 仓）→ 任务里 `@Library('devopslib') _` 或隐式加载（本实验
implicit 全局注册，file:/// 指向挂载进容器的 git 仓）→ stage 里直接 `hello(name)`。
两个 Jenkinsfile 共用同一个 `hello` 步骤——公共逻辑单点演进。

## 5. Groovy 关键字段

```groovy
// 种子脚本：注册共享库（新插件包里的类名已改：SCMSourceRetriever 而非旧文档的 SCMSourceRetrieval）
def lib = new LibraryConfiguration('devopslib',
    new SCMSourceRetriever(new GitSCMSource('file:///var/jenkins_home/shared-lib')))
lib.implicit = true
lib.defaultVersion = 'master'

// 凭据创建（新包：StringCredentialsImpl 在 plain-credentials 插件里）
store.addCredentials(Domain.global(),
    new StringCredentialsImpl(CredentialsScope.GLOBAL, 'registry-pass',
        'lab registry password', Secret.fromString('supersecret123')))
```

坑清单（全部真实踩过，本实验是全系列修得最久的）：

- **坑① 新 credentials 插件删除了 StringCredentialsImpl**：报
  "Could not find credentials entry with ID"——改用 plain-credentials 插件的同名类
  （完整包名 org.jenkinsci.plugins.plaincredentials.impl）；
- **坑② init 脚本编译期看不到部分插件类**：credentials 类在 init.groovy.d 里
  "unable to resolve class"（workflow 类却可以）——凭据创建不能放 init 脚本；
- **坑③ SCMSourceRetriever 拼写**：新插件包里是 Retriever 不是 Retrieval；
- **坑④ Domain.global()**：domains 包里没有 Global 类，全局域是 `Domain.global()`；
- **坑⑤ crumb 绑定 Web 会话**：脚本认证用 API Token（种子脚本生成并落盘），免 crumb。

## 6. 文件结构

```
17_jenkins_advanced/
├── README.md                        # 本教程
├── jenkins_advanced.sh              # apply / leak / clean
├── Dockerfile + plugins.txt         # 派生镜像（+git 插件）
├── credentials.xml                  # 备用：XML 方式注入凭据
├── init.groovy.d/
│   ├── 01-setup.groovy              # 管理员 + API Token + 4 executors
│   └── 02-jobs.groovy               # 凭据 + 共享库注册 + 两个任务
├── shared-lib/
│   └── vars/hello.groovy            # 共享库步骤（被两个流水线复用）
└── images/                          # 图三件套（json/html/svg）
```

## 7. 深入要点

- **parallel stage 的执行模型？** 每个分支占一个 executor 同时执行；任一分支失败
  默认整体失败（failFast 可加速互斥失败场景）。
- **Jenkins 凭据的存储与掩码机制？** 凭据存 JENKINS_HOME 的 credentials.xml（Secret
  加密）；withCredentials 绑定的变量值在日志写出时被 credentials-binding 插件替换为
  \*\*\*\*；直接 echo 变量插值则不打包码（反面教材所示）。
- **Shared Library 的目录约定与版本管理？** vars/（全局步骤）、src/（Groovy 类）、
  resources/；生产用 git 仓库 + 版本 tag，@Library('lib@v1.2') 钉版本。
- **为什么并行不是免费的？** executor 资源消耗、下游共享资源竞争（同一 registry 并发
  推送限速）；并行度要匹配资源而非越多越快。

## 8. 总结

Jenkins 的工程化三板斧齐了：并行省时间、凭据保安全、共享库防分叉。实验 18 换到
Gitea + Actions——轻量 Git 平台自带 CI，GitHub 兼容语法，push 即触发，体验
"云原生 CI"的简洁。
