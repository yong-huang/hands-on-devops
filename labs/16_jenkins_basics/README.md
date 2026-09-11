# 16 · Jenkins 基础：Pipeline as Code 与一次构建的一生

> Jenkins 是 CI 的活化石，也是 CI 深水区。本实验不点鼠标：派生镜像预装插件、
> `init.groovy.d` 种子脚本启动即建任务、REST API 触发构建、断言 SUCCESS 与制品归档——
> 全部代码化，与 Web UI 操作一一对应。失败 stage 的红灯与日志，也一并取证。

## 1. 为什么需要它

Jenkins 的 Web 向导式上手有个陷阱：点出来的配置不在 git 里，坏了无法重建。
Pipeline as Code 的两层含义：**任务定义即代码**（Jenkinsfile/种子脚本）+
**任务执行即代码**（声明式 pipeline 的 stage）。本实验把两层都落进仓库。

## 2. 总览：核心机制一图看懂

![jenkins basics](images/jenkins_basics.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/16_jenkins_basics/images/jenkins_basics.html)
> （或本地打开 [`images/jenkins_basics.html`](images/jenkins_basics.html)）。

看图方法：上半是启动即配置——种子脚本创建任务；下半是一次构建的一生——API 触发、
executor 分配、三个 stage、结果与制品回传。最后两步演示失败注入的红色回路。

## 3. 快速开始

```bash
cd labs/16_jenkins_basics
./jenkins_basics.sh            # apply → fail → clean
./jenkins_basics.sh fail       # 单独重放失败 stage 演示
```

真实输出（关键节点）：

```
=====> [apply] 触发 release-lite → 断言 SUCCESS + 制品归档
        构建 #1 结果: SUCCESS
        归档制品: webapp.tar.gz
        [ok] 全流程绿（test → build → publish → archive）
=====> [fail] 注入失败的 stage
        构建 #1 结果: FAILURE
        失败 stage 日志：+ echo injecting failure
        [ok] 失败 stage 红灯 + 日志可追溯
```

## 4. 核心概念

### 4.1 声明式 Pipeline：stage 即责任边界

```groovy
pipeline {
    agent any
    stages {
        stage('test')    { steps { sh '...' } }
        stage('build')   { steps { sh '...' } }
        stage('publish') { steps { archiveArtifacts 'webapp.tar.gz' } }
    }
    post { always { echo 'release-lite finished' } }
}
```

每个 stage 独立记录状态与日志——失败时控制台直接定位到"哪个阶段、哪行命令"。
失败演示里 `exit 1` 的 test stage 让整个 build 标红，后续 stage 全部跳过。

### 4.2 启动即配置：init.groovy.d

Jenkins 启动时执行 `/var/jenkins_home/init.groovy.d/*.groovy`。本实验用它创建
管理员、设置 executor、注册两个流水线任务——Jenkins 从第一次启动起就是代码定义的
形态。这就是 Jenkins 世界的 GitOps（升级形态是 JCasC 插件）。

### 4.3 API 驱动：crumb 绑定会话

Jenkins 的 POST 请求要求 CSRF crumb，且 **crumb 绑定 Web 会话**——GET crumb 与
POST 必须共用同一 cookie jar（本脚本用 `-c/-b tmp/cookies`）。构建结果用
`/job/<name>/<n>/api/json` 断言：`result=SUCCESS`、`artifacts[0].fileName`。

### 4.4 失败注入：测试流水线的红灯

`release-lite-fail` 任务在 test 阶段 `exit 1`。真实日志：

```
+ echo injecting failure
injecting failure
script returned exit code 1
```

红灯必须有日志、日志必须能定位到命令——这是流水线可信的前提。

## 5. Groovy/Dockerfile 关键字段

```dockerfile
FROM jenkins/jenkins:lts-jdk17
USER root                                   # 坑③：基础镜像默认 jenkins 用户
COPY plugins.txt /tmp/plugins.txt
RUN jenkins-plugin-cli -f /tmp/plugins.txt  # 构建期装插件，运行期即就绪
USER jenkins
```

```groovy
jenkins.setNumExecutors(2)                  // 并行 stage（实验 17）需要 ≥2 executor
```

坑清单（全部真实踩过）：

- **坑① 新版镜像运行时不自动装 plugins.txt**：必须在派生镜像里跑 `jenkins-plugin-cli`；
- **坑② RUN 默认是 jenkins 用户**：无权限写 `/usr/share/jenkins/ref/plugins`，
  报 "Unable to move ... to the plugin directory"——`USER root` 提权后恢复；
- **坑③ crumb 绑定会话**：API POST 403 时先检查 cookie jar 是否共享；
- **坑④ 关向导**：`-Djenkins.install.runSetupWizard=false`，否则首次启动卡在解锁页。

## 6. 文件结构

```
16_jenkins_basics/
├── README.md                    # 本教程
├── jenkins_basics.sh            # apply / fail / clean
├── Dockerfile                   # 派生镜像（预装插件）
├── plugins.txt                  # 插件清单（workflow-aggregator 等）
├── init.groovy.d/
│   ├── 01-security.groovy       # 管理员 + executor + 授权策略
│   └── 02-jobs.groovy           # 种子创建 release-lite / release-lite-fail
└── images/                      # 图三件套（json/html/svg）
```

## 7. 深入要点

- **声明式与脚本式 pipeline 的取舍？** 声明式结构固定（stages/post）、易读易审计；
  脚本式（Groovy 自由代码）表达力强但难维护。默认声明式，个别逻辑下沉到共享库。
- **Jenkins master/agent 架构的意义？** controller 只做调度与 UI，构建负载在 agent；
  隔离环境、横向扩容、故障域分离（实验 17 的 docker agent 是其容器化形态）。
- **凭据如何安全管理？** credentials 插件 + withCredentials 绑定，日志自动打码
  （实验 17 演示）；绝不 echo 密码、绝不把 secret 写进 workspace。
- **Jenkins 的"配置漂移"怎么治？** 配置即代码：种子脚本/JCasC + 插件清单入 git，
  controller 无状态化（数据卷只留构建历史）。

## 8. 总结

Jenkins 的最小可信单元已经就位：代码化任务、API 驱动、红灯可取证。实验 17 下潜：
并行 stage 压时间、credentials 管密码、Shared Library 抽公共逻辑——Jenkins 深水区。
