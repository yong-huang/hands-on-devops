# 05 · Runner 注册与标签资源池

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 5 · 阶段二「Runner 农场与执行环境」
> 两个 docker executor runner（eda/fpga）按标签路由，concurrent=2 的排队行为用时间戳实测证明
> 验收①②在 `runner_farm.sh`：标签路由 + 干净测量下的排队时序，全过打 `[ok]`

## Background

平台（01）和载体（03）都有了，但没有 runner 的 GitLab 只是代码托管——CI/CD 的执行力全在 runner 这一侧。

半导体公司的 runner 农场有个鲜明特征：**按标签分池**（eda 池跑仿真、fpga 池跑综合），不同 stage 的计算特征天差地别。池子还要有**并发上限**——License 并发和内存都是稀缺资源，来者不拒会把农场打爆（项目 14 的门禁）。

本实验立起两台 runner（eda 池 concurrent=2、fpga 池 concurrent=1），并用一个观察靶场（runner-lab 项目）证明两件事：job 会按 `tags:` 精确落池；第 3 个 job 会在并发满时**排队等腾位**。

## What

心智模型一句话：**runner = 挂着标签的工人，concurrent = 它有几只手**。

| 组件 | 形态 | 关键配置 |
|:---|:---|:---|
| runner-eda | gitlab-runner 容器（docker executor） | tags=[eda]，concurrent=2 |
| runner-fpga | gitlab-runner 容器（docker executor） | tags=[fpga]，concurrent=1 |
| runner-lab | GitLab 项目 | 3 个 eda job（各 sleep 6）+ 1 个 fpga job |

两条关键接线：runner 容器与 job 容器都进 `semi-gitlab_default` 网络（01 的 compose 网络），所以 runner 的 url、job 的 clone_url 都用 `http://gitlab/` 内网名直连。

runner 还要挂宿主 `/var/run/docker.sock`（docker executor 靠它创建 job 容器）。验证方法：`./runner_farm.sh status` 看在线状态，`./runner_farm.sh verify` 跑两条断言。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 不同 stage 需要不同执行环境/资源 | 标签分池（本实验）：job 用 `tags:` 点菜，runner 用 tag 应募 |
| License/内存限并发 | runner 级 `concurrent`（本实验）；跨 runner 的全局配额要靠门禁服务（项目 14） |
| job 需要访问平台内网组件 | `network_mode` 把 job 容器塞进 GitLab 网络（本实验）——比暴露端口到宿主干净 |
| 大量 job 蜂拥而至 | 认识排队语义：concurrent 满即排队，`time_in_queue_seconds` 是容量规划的核心指标 |

## Quick Start

前置：项目 1-4 完成（平台在线）；OrbStack 正常（本实验开始前实测过一次 OrbStack 因卡死的 pull 整机僵死，`osascript quit + open -a OrbStack` 应用级重启可救，容器卷无损）。

```bash
./runner_farm.sh up      # 签发令牌 + 落两个 runner + 灌靶场流水线（约 2 分钟）
./runner_farm.sh verify  # 两条断言（等待空闲→干净测量→排队证明）
./runner_farm.sh status  # runner 在线状态
./runner_farm.sh clean   # 删 runner 与靶场项目
```

`up` 的关键输出（实测）：

```
=====> [runner] 签发 glrt 令牌并落两个 runner（eda concurrent=2 / fpga concurrent=1）
  [ok]   runner-eda 注册有效（tags=[eda] concurrent=2）
  [ok]   runner-fpga 注册有效（tags=[fpga] concurrent=1）
=====> [lab] runner-lab 靶场项目 + 观察流水线
[ok] .gitlab-ci.yml 已提交（首次会自动触发流水线）
```

`verify` 的真实输出（两条全过）：

```
=====> [verify] 验收① 标签路由：job 落到带对应标签的 runner
  [ok]   eda-1 由 runner-eda 执行（tags=[eda] 路由生效）
  [ok]   fpga-probe 由 runner-fpga 执行
=====> [verify] 验收② concurrent=2 排队：第 3 个 eda job 晚于首批完成才起跑
         起跑排序间隔：0.6s / 9.8s（job 时长 6s，并发=2 → 第二间隔应 ≥4s）
  [ok]   并发上限生效：第 3 个 job 排队等首批腾位

[ok] 项目 5 全部验收断言通过
```

诚实预期：`verify` 先等 runner 空闲再触发新流水线（农场里压着前几轮积压 job 时，跨流水线交错会让时序断言失真——这是本实验的测量学教训）；OrbStack 重启后 API 偶发空响应，脚本里 GET/POST 都带重试。

## How It Works

### 注册的新流程：glrt 认证令牌 + 声明式 config.toml

老教程的 registration token 在 GitLab 16.0 已移除。新流程分两步：管理员 API `POST /user/runners` 签发一次性 `glrt-` 令牌。

把它写进 runner 的 `config.toml`（`[[runners]] token=`）即完成注册。

注册本来就是"写配置文件"，所以本实验跳过 `gitlab-runner register` 交互命令，直接用模板注入（configs/config.toml.template）。

幂等重放的坑：清理旧 runner 必须查 `GET /runners/all`——`GET /runners` 对 admin 也有可见性过滤（实测返回空列表），漏删会让同名 runner 越积越多。

### docker executor 的两条网线

runner 容器自己进 `semi-gitlab_default` 网络是为了连 GitLab；**job 容器**能不能连 GitLab 取决于 `runners.docker.network_mode`——它决定 runner 通过宿主 docker.sock 创建的 build/helper 容器加哪个网络。

不设的话 job 容器在默认 bridge 里，`clone_url=http://gitlab/` 解析不了直接 clone 失败。验证：runner 日志里 `repo_url` 显示的是 GitLab 下发的原始地址，实际 clone 用的是 clone_url 重写。

### 排队测量的方法论

`started_at` 是唯一诚实的排队证据。三个 eda job 同流水线到达时，concurrent=2 的行为是：两个立即起跑（间隔 <1s），第三个等任一完成（6s job → 间隔 ~9s）。

**测量前必须等 runner 空闲**——农场里压着上一轮的 job 时，本流水线的 eda-2 可能先抢到别的空位，排序间隔直接失真（实测见过 -14.4s）。空闲判定只认 JSON 数组：404 的 dict `len()==1` 会冒充"有 1 个 running"。

## Pitfalls & Q&A

**坑 1：python-gitlab 的 `runners.create` 走老端点。** 它 POST /runners（要已废除的 registration token）。新流程用 `gl.http_post("/user/runners", post_data={...})` 裸调。

同理清理用 `gl.http_get("/runners/all")`（`gl.runners.all` 是方法不是 manager）。

**坑 2：函数输出当返回值用。** `out=$(wait_pipeline)` 会把函数里所有进度 echo 一起捕获，`awk '{print $1}'` 取到的是 `=====>`。约定：函数最后一行只输出 ids，调用方 `tail -1` 取。

**坑 3：OrbStack 偶发空响应。** 重启过 VM 后实测 API 偶发返回空 body（GET/POST 都会），脚本 GET/POST 全部带重试；python-gitlab 侧开 `retry_transient_errors=True`。

**Q：job 的 `repo_url` 日志还是 localhost:28200，clone 为什么成功？** 那是 coordinator 下发的原始字段；runner 用 `clone_url` 重写了实际 clone 地址，日志字段不改写。

**Q：为什么 runner-fpga concurrent=1？** FPGA 综合是单大任务特征（下个阶段），1 并发即串行队列——不同池不同并发是农场的常态而非对称配置。

**Q：up 重放会怎样？** bootstrap 先删旧 runner（/runners/all 全量找）再建新的，config.toml 重新注入新 glrt 令牌；靶场 yml 幂等更新（内容一致跳过提交）。
