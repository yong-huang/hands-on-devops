# 03 · 状态管理深潜：远端 state、锁与 mv/rm/import 三板斧

> 实验 1-2 的 state 一直躺在 `configs/terraform.tfstate`。一个人玩没问题；两个人（或两台 CI）
> 同时 apply 会怎样？——本地 state 没有任何并发保护，谁后写谁覆盖，资源被"记忆错乱"的 TF
> 拆掉重建。本实验把 state 挪进远端（MinIO 冒充 S3，零云依赖），把锁、改名、收编一次讲透。

## 1. 为什么需要它

本地 state 的三宗罪：

- **协作冲突**：state 是单文件，A、B 各自 pull-modify-write，后写者覆盖前写者；
- **CI 无法工作**：流水线机器上没有最新 state，plan 全是"从零创建"；
- **不敢换机器**：state 丢了 = TF 忘了自己管过什么，资源成了孤儿。

解法是把 state 放到远端对象存储（S3 协议是事实标准）+ 后端锁。S3 API 兼容的 MinIO
让这一切在笔记本上就能演练。

## 2. 总览：核心机制一图看懂

![tf state](images/tf_state.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/03_tf_state/images/tf_state.html)
> （或本地打开 [`images/tf_state.html`](images/tf_state.html)）。

看图方法：上半段是工程师 A 的正常 apply——拉 state、上锁、改基础设施、写回、放锁；
下半段是工程师 B 在 A 持锁期间发起 plan——后端直接拒绝（412），报错里带着锁的持有人信息。

## 3. 快速开始

```bash
cd labs/03_tf_state
./tf_state.sh            # backend → apply → stateops → sensitive → lock → clean
./tf_state.sh lock       # 只看锁互斥演示
```

MinIO 由脚本拉起（`localhost:9000`，控制台 `:9001`，账号 minioadmin/minioadmin），
bucket 自动创建。真实输出（节选）：

```
=====> [backend] 启动 MinIO（S3 兼容）并初始化远端后端
Successfully configured the backend "s3"!
=====> [apply] 创建 2 个资源，state 落在 MinIO
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```

## 4. 核心概念

### 4.1 锁：`.tflock` 就是后端里的一个对象

TF 1.10+ 的 S3 后端用"原生锁文件"（`use_lockfile = true`）——锁就是 `terraform.tfstate.tflock`
这个对象。apply 先条件写入它（谁先写谁得锁），结束后删除。持锁期间 B 的 plan 真实报错：

```
Error: Error acquiring the state lock
│ StatusCode: 412, ...
│ Lock Info:
│   ID:        11111111-2222-3333-4444-555555555555
│   Operation: OperationTypeApply
```

进程崩溃会留下"死锁"——报错信息里的 ID 就是恢复凭据：`terraform force-unlock -force <ID>`。
**坑**：不开 `use_lockfile = true` 时 S3 后端完全没有锁检查，两个人同时 apply 后端一声不吭。

### 4.2 state mv：改名不重建

把配置里 `docker_volume.db` 改成 `database`（sed），再用 mv 让 state 追上：

```
Move "docker_volume.db" to "docker_volume.database"
        plan exit=0（0 = 纯改名，没有销毁重建）
```

plan 为空说明 TF 只是换了"账本上的地址"，实际卷纹丝不动。**没有 mv 会怎样**：
配置改名后 plan 会显示"销毁 db + 创建 database"——一个名字引发一次真实重建。

### 4.3 state rm 与 import：遗忘与收编

```
Removed docker_container.keeper          # state rm：TF 遗忘了它
        Plan: 1 to add, 0 to change, 0 destroy.   # 但配置里还有 → plan 想重建
        卷 tf03-db 仍在：tf03-db          # 对比：真实对象毫发无损
```

`state rm` 不是删除资源，是"从账本上划掉"——之后 destroy 也不会碰它。
反向操作是 `import`：手动 `docker volume create` 出来的野生卷，写入配置后
`terraform import docker_volume.orphan tf03-orphan`，从此纳入 TF 管理。

### 4.4 sensitive 只遮住输出，遮不住 state

```
$ terraform output token_masked
token_masked = <sensitive>          # 输出层：打码 ✓

$ mc cat m/tfstate/lab03/terraform.tfstate | grep super-secret
        state 明文包含: super-secret-token-do-not-commit   # state 层：明文 ✗
```

结论：`sensitive = true` 只是 UI 层不回显；state 文件永远明文。所以后端存储本身的
访问控制（bucket 权限、加密）才是安全边界——实验 24 的 SOPS 治理的是另一头（配置里的密钥）。

## 5. HCL 关键字段

```hcl
backend "s3" {
  endpoints = { s3 = "http://localhost:9000" }   # TF 1.11+ 新写法（旧名 endpoint 已废弃）
  bucket    = "tfstate"
  key       = "lab03/terraform.tfstate"

  use_lockfile = true        # 不开 = 没有锁检查！本实验最重要的开关

  skip_credentials_validation = true   # MinIO 不是真 AWS：
  skip_metadata_api_check     = true   # 关掉四类 AWS 专属校验
  use_path_style              = true   # MinIO 走 path-style（bucket 在路径里），
}                                      # AWS 新区走 virtual-hosted，别搞混
```

坑清单：

- **坑① 锁参数写错位置**：`lock_timeout` 不是 backend 参数，是 CLI 的
  `-lock-timeout=5s`；
- **坑② 本地缓存复活**：`configs/.terraform/` 里有 state 快照缓存，远端清空后重 init
  可能被旧缓存"带节奏"——换后端/清远端时顺手 `rm -rf .terraform`；
- **坑③ 两个工作目录共享一个 backend**：worker-A、worker-B 各自 init 同一个 key——
  这正是锁要保护的场景。实验脚本用 `tmp/worker-a|b` 模拟两个工程师（已 gitignore）。

## 6. 文件结构

```
03_tf_state/
├── README.md                # 本教程
├── tf_state.sh              # 主演示脚本：backend/apply/stateops/sensitive/lock/clean
├── configs/
│   ├── versions.tf          # s3 backend 指向 MinIO + use_lockfile
│   └── main.tf              # 极少资源：主角是 state（mv/rm/import/sensitive 演示台）
├── tmp/                     # 运行时生成的两个"工程师工作目录"（gitignore）
│   ├── worker-a/
│   └── worker-b/
└── images/                  # 图三件套（json/html/svg）
```

## 7. 深入要点

- **远端 state 解决什么问题？** 协作一致性（单一真相）、CI 可用性、以及配合锁解决并发。
  本地 state 只有"一个人能用"。
- **状态锁的机制与恢复？** 锁 = 后端里的锁文件（S3 是 .tflock，条件写实现互斥）；
  进程崩溃留下死锁时用 `force-unlock <ID>` 强制释放——前提是确认真的没人持锁。
- **state mv / rm / import 各用于什么场景？** mv=重构资源地址（改模块结构/改名）不重建；
  rm=让 TF 遗忘某资源（移交别的系统管理）；import=收编已存在的基础设施（IaC 化存量）。
- **state 里为什么会有敏感信息？** state 记录资源实际属性，密码/token 是属性的一部分。
  缓解：后端加密与权限、`sensitive`（仅输出层）、或把密钥挪到专门系统（Vault/SOPS）。
- **多人协作的 IaC 工作流？** 短命分支 + plan 输出贴 PR + approve 后 CI 统一 apply；
  谁也不在本地 apply——锁是兜底，流程才是主防线。

## 8. 总结

state 上远端 + 锁 + 三板斧（mv/rm/import）之后，TF 才是"团队工具"而不是"个人备忘录"。
本实验的 MinIO 会在实验 5 正式编入靶场（它同时是后续镜像仓的 S3 存储）。
下一步解决另一个重复问题：dev/staging 两套环境，是复制目录还是用 workspace？——实验 4
两种组织法各实现一遍。
