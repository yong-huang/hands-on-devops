# 23 · 备份与容灾：gitlab-backup 全量 + 恢复演练

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 23 · 阶段六「生产化」
> 备份（7.2G 含 LFS）→ 毁容器毁卷 → 新容器恢复 + secrets → API/clone/LFS 三层断言，RTO 262 秒
> 验收在 `dr.sh` 全流程：备份生成 / 恢复后 API+clone+LFS 三层断言，全过打 `[ok]`

## Background

平台所有实验的产出都在 GitLab 里——备份是容灾的最后防线。

GitLab 的备份模型有个反直觉的关键点：`gitlab-backup create` **不包含** `/etc/gitlab/gitlab-secrets.json`（加密数据库字段用的密钥）——漏拷 secrets 的备份，恢复后 CI 变量解不开、LFS 打不开、token 全失效，等于没备。

本实验真刀真枪演练一次：备份 → 毁掉容器与数据卷 → 新容器恢复 → 三层功能断言 + RTO 计时。

## What

心智模型一句话：**备份 tar 管数据，secrets 文件管钥匙——两个都到家，恢复才算完成**。

| 产物 | 说明 |
|:---|:---|
| `<ts>_<ver>_gitlab_backup.tar` | DB+仓库+LFS 引用（7.2G，含历史 LFS 对象） |
| gitlab-secrets.json | db 加密密钥（backup 不含，需手动 docker cp 拷出） |
| gitlab.rb | 配置（本实验是 bind mount 自仓库，恢复时无需覆盖） |

RTO 实测：**262 秒**（毁卷→新容器→恢复→secrets→功能可用）。验证方法：`./dr.sh` 全流程的 verify 三层断言。

## When to Use

| 场景 | 做法 |
|:---|:---|
| 定期容灾演练 | `./dr.sh` 全流程（本实验）——恢复演练不演练就是没备份 |
| 升级前保险 | backup → 升级 → 出问题 restore |
| 跨机迁移 | backup tar + secrets 拷到新机 → 同流程恢复 |

## Quick Start

前置：平台在线；磁盘余量 ≥10G（备份 7.2G + LFS 历史）。

```bash
./dr.sh backup    # gitlab-backup create + secrets 拷出（约 3 分钟）
./dr.sh restore   # 毁容器毁卷 → 恢复 → 三层断言（约 8 分钟，破坏性！）
./dr.sh status    # 备份清单
```

`restore + verify` 的真实输出（实测，全过）：

```
=====> [restore2] gitlab-backup restore（force=yes）
..[ok] GitLab 就绪（耗时 20s）
[ok] RTO: 262 秒
=====> [verify] 恢复后功能断言（API/仓库/LFS 三层）
  [ok]   API：rtl-gcd 项目可见（id=10）
  [ok]   git clone 正常（secrets 恢复 → token 链路有效）
  [ok]   LFS 对象可拉取（fake.gds 实体回来）

[ok] 项目 23 全部验收断言通过
```

## How It Works

### 恢复的三层断言设计

恢复后按依赖层次逐层验：API 层（项目可见 = DB+secrets 对）、git 层（clone+PAT = secrets 链路通）、LFS 层（实体可拉 = 对象存储引用对）。

每层定位一类故障：DB 恢复失败在 API 层暴露，secrets 缺失在 clone 层暴露（PAT 校验依赖加密字段），LFS 路径错在对象层暴露。

### secrets 的关键性实证

PAT 的校验依赖 secrets 加密的字段；gitlab-secrets.json 缺失/不一致时，数据库里的密文解不开——clone 的 PAT 认证链路就断。verify 的 clone 断言事实上同时验证了 secrets 恢复的正确性。

### RTO 的组成

毁卷→新容器启动（~100s）→ gitlab-backup restore（DB+仓库+LFS 解包，~60s）→ secrets+reconfigure+restart（~60s）→ 三层断言（~40s）= 262s。

生产环境 RTO 由备份体积与恢复自动化程度决定——脚本化演练就是压缩 RTO 的手段。

## Pitfalls & Q&A

**坑 1：备份 tar 拷贝进卷的路径。** 恢复要求 tar 在 `/var/opt/gitlab/backups/` 下——alpine 容器 cp 时要 `mkdir -p /target/backups` 且 **chmod 777**。

原因：restore 以 git 用户读 tar，而预置容器 cp 落盘的是 root 属主。

**坑 2：扩展属主错误会中断 restore。** 新卷初始化时扩展属主是 `gitlab-psql` 角色，备份的 pg_restore 以 gitlab 运行 `DROP EXTENSION` 直接报 must be owner 并中止。

修法：restore 前以 gitlab-psql 角色 `ALTER EXTENSION ... OWNER TO gitlab`（三个扩展）。

**坑 3：gitlab.rb 是 ro bind mount，docker cp 覆盖会报 device busy。**

配置本来就来自仓库（01 的演进链），恢复时无需覆盖——只恢复 secrets。

**Q：备份里为什么有 7.2G？** LFS 的历史对象（P12 的 2GB×多轮 + P22 的 airgap 实验）全在备份里。生产上应配 cleanup 策略控制 LFS 增长，或备份窗口分级（DB 日备、LFS 周备）。

**Q：RTO 262s 里哪段最值得优化？** restore 的解包（~60s）与 restart（~60s）是固定成本；真正可压缩的是"发现灾难到开始恢复"的人因时间——脚本化演练（本实验）就是压缩它。
