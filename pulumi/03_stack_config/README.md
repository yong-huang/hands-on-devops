# 03 · Stack 与配置：一份程序，多套环境

> 同一份 `index.ts` 要同时服务 dev 和 prod——端口、镜像、问候语全都不同。把这些
> 差异写进代码就是复制粘贴的开端；Pulumi 的答案是 stack（配置命名空间 + 独立账本）：
> 程序只管读配置，每个环境一套参数、一本账，互不干扰。敏感值用 `--secret` 加密
> 存进配置与 state，全程不落明文。

## Background

项目 1、2 的程序只有一套环境。现实里同一份程序至少要跑 dev 和 prod：端口要错开、
镜像版本分稳定/预览、生产参数谁都不能写死在代码里——改一处就要同步改 N 处，
还容易把生产密码顺手提交进 git。

Terraform 用 workspace（切换式：一套配置文件，激活哪个就是哪个）或目录法
（每环境复制一份）解决，敏感值靠 tfvars 明文 + 外部加密工具兜底（见
[`labs/04_tf_environments`](../../labs/04_tf_environments/)）。Pulumi 把"多环境"
做成一等公民：stack 是命名式的——每个环境一个名字、一份独立配置文件、一本独立
state 账本，可同时部署、互不干扰。

## What

**定义**：stack 是同一程序的一次命名执行环境——独立的配置（`Pulumi.<stack>.yaml`）
+ 独立的账本（state）。config 是挂在栈上的键值参数；标了 `--secret` 的键在文件、
state 与 CLI 输出里全程密文。

| 部件 | 角色 |
|:---|:---|
| `pulumi stack init/select/ls/rm` | 建栈、切栈、列栈、删栈（本实验的主角） |
| `Pulumi.dev.yaml` / `Pulumi.prod.yaml` | 每栈一份配置文件，进 git（里面是密文） |
| `pulumi config set [--secret]` | 写配置；`--secret` 落盘即加密 |
| `pulumi.Config`（程序内） | 读配置：`requireNumber` / `require` / `requireSecret` 类型化三件套 |
| `PULUMI_CONFIG_PASSPHRASE` | 密钥口令——secret 的解密钥匙，丢了密文就永远解不开 |

可以把 stack 想成同一份装修图纸的两张施工单：一张"张家公寓"、一张"李家别墅"，
各自附参数表（端口、颜色）与施工账本；图纸（程序）只有一份，改图纸两张单都生效，
改某张单的参数只影响那一户。

![一份程序两套环境：配置分支与账本隔离](images/stack_config.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/pulumi/03_stack_config/images/stack_config.html)（或本地打开 [`images/stack_config.html`](images/stack_config.html)）。

看图方法：左边一份程序 `index.ts` → `up -s dev` / `up -s prod` 两条分支 →
各自读 `Pulumi.dev.yaml` / `Pulumi.prod.yaml` 的参数 → 建各自的容器、记各自的
state 账本；右下三个面板分别是配置三件套、隔离实测与 at rest 密文形态。

## When to Use

- 同一程序要部署多套环境（dev / staging / prod），参数各不相同；
- 参数里有机密（密码、token、私钥），不能明文进 git、也不能明文进 state；
- 多套环境要**同时在线**并互不影响（workspace 的切换模型做不到并存）。
- 反之：只有一个环境时别急着拆栈——多栈的代价是配置与账本都要按栈维护。

## Quick Start

前置：Pulumi CLI（`brew install pulumi`）、Node.js 22、Docker 运行中。

```bash
cd pulumi/03_stack_config
./stack_config.sh          # 完整生命周期：apply → observe → stacks → rotate → clean
./stack_config.sh apply    # 同一程序建 dev/prod 两栈并各自 up
./stack_config.sh observe  # 配置读法 + "密文三层"证据
./stack_config.sh stacks   # 隔离验证（destroy dev，prod 不动）+ stack rm 演示
./stack_config.sh rotate   # 只改 dev 的 secret，观察定向更新
./stack_config.sh clean    # 两栈 destroy 全清
```

`apply` 的真实输出（dev 栈节选；prod 同理，端口 28202）：

```
Updating (dev):

 +  docker:index:Container web created (1s) 
Outputs:
    greeting: [secret]
    url     : "http://localhost:28201/"

Resources:
    + 2 created
```

随后脚本用 docker 视角验证两套并存：`pulumi03-dev-web` 跑 `nginx:1.27-alpine` 于
28201、`pulumi03-prod-web` 跑 `nginx:1.25-alpine` 于 28202，两个端口 curl 都命中
nginx 欢迎页——同名资源逻辑名 `web` 在两个栈里互不撞名。

诚实预期：首次运行先 `npm install`（约 1 分钟）；28201/28202 被占用会在 curl 断言
处报错；secret 的加解密需要口令，实验用固定值 `PULUMI_CONFIG_PASSPHRASE`（真实
项目接密钥管理，见 [`labs/06_ansible_role_vault`](../../labs/06_ansible_role_vault/)）。

## How It Works

### 程序侧：读配置三件套，不写死任何环境参数

```ts
const stack = pulumi.getStack();                 // 程序知道自己正被哪个环境执行
const port = config.requireNumber("port");       // 类型化读数字
const image = config.require("image");
const greetingSecret = config.requireSecret("greeting");   // 敏感值，Output<string>

const web = new docker.Container("web", {
    name: `pulumi03-${stack}-web`,               // 真名按栈派生：dev/prod 不撞名
    image,
    ports: [{ internal: 80, external: port }],
    envs: [pulumi.interpolate`SITE_GREETING=${greetingSecret}`],
});
```

逻辑名都是 `"web"`，但 state 身份（URN）里带着栈名——
`urn:pulumi:dev::pulumi03-stack-config::docker:index/container:Container::web` 与
`urn:pulumi:prod::…::web` 是两个独立资源。环境差异全部来自配置，程序零 `if (env === "prod")`。

### 配置侧：每栈一份 yaml，写一次 `config set` 就落盘

`Pulumi.dev.yaml`（进 git，敏感值是密文）：

```yaml
config:
  pulumi03-stack-config:port: "28201"
  pulumi03-stack-config:image: nginx:1.27-alpine
  pulumi03-stack-config:greeting:
    secure: v1:p91bqTTnRGXzzHt9:/4Az5NgwGPAXjQI9xVt75Jxyt6f1wSie…
```

### 密文三层：at rest 全程密文，运行时才解密

`observe` 段的三条证据（真实输出）：

1. **yaml 与 state 零明文**：全量扫描 `Pulumi.dev.yaml` 与 `.pulumi-state/`，
   明文 0 命中——`--secret` 写入即用每栈独立的 `encryptionsalt` 加密；
2. **CLI 输出打码**：`up` 的 Outputs、`pulumi config` 表格里都是 `[secret]`；
3. **运行时才可见**：部署时解密注入容器环境——
   `docker inspect` 可见 `dev-web  SITE_GREETING=dev-greeting-secret`。

注意边界：`pulumi config get greeting` 会打印明文——这条命令本来就是"给你自己
看"的；secret 保护的是**落盘形态**（git 里的 yaml、磁盘上的 state），不是屏幕。

### 隔离与轮换：账本独立，改一处只动一栈

`stacks` 段 `destroy` 掉 dev：dev 容器消失，prod 的 28202 照常返回 nginx 首页——
两本账互不引用。带资源的栈直接 `stack rm` 会被拒绝（实测）：

```
error: 'dev' still has resources; removal rejected. Possible actions: …
```

`rotate` 段只对 dev 换 secret 再 `up`，真实输出（节选）：

```
 +- docker:index:Container web replacing (0s) [diff: ~envs]
Resources:
    +-1 to replace
    1 unchanged
```

diff 只有一行 `~envs` 且值不显示明文；dev 容器内已拿到新值
`dev-greeting-rotated`，prod 原值不动。

### 对照：TF workspace vs Pulumi stack

| 维度 | Terraform workspace（labs/04） | Pulumi stack（本实验） |
|:---|:---|:---|
| 组织方式 | 切换式：一次只有一个激活 | 命名式：多栈并存，可同时部署 |
| 配置差异 | tfvars 文件 / 目录复制 | `config set` 按栈写入，每栈一份 yaml |
| 敏感值 | tfvars 明文，靠外部工具加密 | `--secret` 内置加密进 yaml 与 state |
| 账本 | 各 workspace 一份 state | 各 stack 一份 state，互不引用 |

## Pitfalls & Q&A

- **① 口令是唯一的钥匙**：`PULUMI_CONFIG_PASSPHRASE` 丢失，所有 `--secret` 值
  永久解不开（每栈的 `encryptionsalt` + 口令共同派生密钥）。实验固定口令只为
  可复现，真实项目接密钥管理。
- **② config get 打印明文不是泄漏**：保护边界是落盘形态（yaml / state），命令行
  本来就是给运维本人看的；清单验收标准最初写成"config get 输出密文"，实测纠正。
- **③ destroy 不等于删栈**：destroy 只清资源，栈记录与配置还在（`stack ls` 仍
  可见，RESOURCE COUNT 归零）；要连配置一起删需显式 `stack rm`，且带资源会被拒。

Q&A：

- **`Pulumi.<stack>.yaml` 要提交进 git 吗？** 要：里面是密文，没有口令解不开；
  这正是与 `.tfvars`（明文，得靠 SOPS 这类外部加密，见
  [`labs/24_sops_age`](../../labs/24_sops_age/)）的本质差别。
- **两个栈能共用一个容器名吗？** 真名（`name`）撞了会在 Docker 层冲突——逻辑名
  在栈内唯一即可，真名要自己保证全局不撞（本实验按栈名派生真名）。
- **state 文件里能看到 secret 吗？** 不能：`.pulumi-state/` 全量 grep 明文 0 命中
  （`observe` 段实测），敏感属性以密文存储。
