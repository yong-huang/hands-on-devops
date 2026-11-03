# 28 · 配置漂移检测与治理：三类漂移 × 双探针 + 专项 × 一键回正

> 期望态由 TF（基础设施）+ ansible（容器内配置）分层管理；三类漂移逐类注入 → 分类定位 → 一键回正 → 终态四断言。tag 被覆盖的 registry 层漂移是 TF/ansible 的**双盲区**——专项 digest 探针补位。

## Background

漂移 = 实际态偏离声明态。检测工具按漂移层各管一段：`terraform plan -detailed-exitcode`（0=无/2=有）管基础设施、`ansible-playbook --check`（0 changed=无）管配置，但**registry 层（同 tag 被覆盖）两家都看不见**——它们只看 tag 字符串不看内容。本实验三轮治理演练实证每类漂移"被正确的探针检出、被正确的动作回正"。

## What

- `tf/main.tf`：期望态（web 容器；**log_opts 显式对齐 daemon 默认值**——见 Pitfalls 1）
- `ansible/playbook.yml`：容器内期望配置（motd + web 根页面，docker 连接免 SSH）
- `images/{app,malicious}.Dockerfile`：干净/劫持两版镜像（同 tag 覆盖演示）
- `configs/drift-sop.md`：治理 SOP（检测→定位→修复→复盘，含分类决策树）
- `drift_detection.sh`：setup → 注入×3 → detect（分类报告 JSON）→ restore → assert-clean（四断言）

## When to Use

- 生产巡检：定期跑 `detect` 相生成漂移报告（JSON 可进告警）
- 事故响应：按 `configs/drift-sop.md` 的分类决策树定位根因，一键回正
- 长期治理：收编变更入口（GitOps，labs/21）让"手动改集群"流程上不可能；合法变更后刷新期望态与 digest 基线

## Quick Start

```bash
cd labs/28_drift_detection
./drift_detection.sh all   # 三轮治理演练（约 8 分钟），全绿两遍验证
./drift_detection.sh detect        # 单独跑检测报告
```

前置：terraform + ansible + community.docker collection；labs/14 的 registry（:5500，脚本自动拉起）；labs/01 的 docker provider 二进制（filesystem mirror 自动 stage）。

## How It Works

### 双探针 + 专项的分工（谁检出什么）

| 漂移 | TF plan | ansible --check | digest 专项 | 根因定位 |
|:---|:---:|:---:|:---:|:---|
| ① 容器内配置手改 | 绿 | **红** | 绿 | 配置层 → ansible 重渲染 |
| ② 手动重建容器（走样） | **红** | — | 绿 | 基础设施层 → TF 重建 |
| ③ registry tag 覆盖 | 绿 | 绿 | **红** | registry 层 → 重推+重建+刷基线 |

detect 相产出 `tmp/drift-report.json`（分类 + 根因），restore 相按报告分支回正——**检测与修复解耦**（检测可独立巡检，修复按报告执行）。

### digest 探针的正确姿势

`docker push` 输出与 registry `Docker-Content-Digest` 响应头**同源**（OCI 格式）；自行 sha256 请求体恒不等（Accept 协商会转换字节表示）。API 路径按 name/tag 拆开：`/v2/<name>/manifests/<tag>`——把 `repo/app:1.0` 整个拼进路径会 404（实测）。

## Pitfalls & Q&A

1. **provider 永久 force-replacement diff**：OrbStack daemon 给容器注入默认 log 轮转（max-file 5/max-size 20m），HCL 不声明时 refresh 恒报 `log_opts forces replacement`——期望态**必须显式对齐 daemon 注入字段**（apply 后立即 plan 验证零 diff 是标准动作）。
2. **ansible 管道无匹配即炸**：`--check` 无变更时输出无 `changed=N`（或 rc=2），`grep | grep | awk` 任一环无匹配 rc=1 → `set -e` 静默退出。全部 `{ grep ... || echo "changed=0"; }` 兜底。
3. **digest 基线/现网读不到要显式报错**：静默空值会造成"空=空"的假 SAME——assert-clean 对基线缺失、registry 不在线都是 fail 而非跳过。
4. **ansible 子进程持 stdin**：命令替换包裹 ansible 时可能挂死——`</dev/null` 断开。
5. **环境断电/daemon 重启后**：registry 与容器都 Exited——脚本 `ensure_registry` 自动拉起；drill 的各相均可独立重跑（幂等）。

## 产物清单

- `tf/main.tf`（期望态 + log_opts 对齐）/ `ansible/playbook.yml` / `images/{app,malicious}.Dockerfile`
- `configs/drift-sop.md`（治理 SOP 决策树）+ `drift_detection.sh`：三轮演练全绿两遍；`tmp/drift-report.json` 分类报告
