# 15 · 蓝图即代码：act 本地 CI 门禁（三 job + 两条负向红线）

> 清单：[docs/cloudify.md](../../docs/cloudify.md) 项目 15 · 阶段四「Kubernetes 与交付闭环」
> 一个 workflow 三个 job（lint+validate / 插件单测 / 本地回路冒烟），外加两条"故意弄坏"的负向 workflow——门禁的价值在于它真的会拦

## Background

实验 01-14 的每个 run.sh 都是"手动的验收"；这一步把它们装进 **CI 门禁**：`cfy blueprints validate`（解析期闸门）、插件 pytest（单元）、本地模式冒烟（install→outputs→uninstall 全链）。跑在 `act`（本地复现 GitHub Actions，复用 cicd/01 的回路）——CI 的完整价值在负向：**坏蓝图必须红、坏断言必须红**，两个负向 workflow 专门验证"门禁真的会拦"。

## What

- `.github/workflows/blueprint-ci.yaml`：三 job——`lint-validate`（cfy-lint + validate 好/坏两份）、`unit`（跑 05 实验插件的 pytest 拷贝）、`smoke`（容器内全新 venv 装 cloudify → 本地模式全回路 → 断言 outputs）
- `.github/workflows/bad-validate.yaml`：坏 node type 蓝图 → 必须红；`bad-unit.yaml`：把 status_code 断言 200 改 999 → 必须红
- `blueprint_ci.sh`：act 三连 + 负向断言（act 退出码非 0）+ 残留检查

## When to Use

- 蓝图仓库的 PR 门禁：validate 必过 + 单测必绿 + 冒烟必通；本地 act 是 GitHub Actions 的免费预演（不推 GitHub 也能跑）
- 蓝图改动的回归：把 run.sh 里的断言搬进 CI，人肉验收变成机器验收

## Quick Start

```bash
./blueprint_ci.sh    # 4 相 20 断言：green / bad-validate / bad-unit / residue（约 2 分钟）
```

前置：act 0.2.89；镜像 `python:3.11-slim`（小层可拉，py 版本对 cloudify 7.0.5 友好）。

## How It Works

### act 的四个本地化坑（全部实测踩过）

1. **workspace 只复制 git tracked 文件**——untracked 的 cloudify/ 在容器里是**空目录**（用 /tmp 临时目录复现实锤）。解法 `--bind`（直挂真实目录，cicd/01 同款经验）。
2. **`--pull` 默认 true**——网络抖动时本地已有的镜像也会 Set up 失败。`--pull=false`（注意 cobra bool 要 `--pull=false`，`-p false` 被拆成两个位置参数）。
3. **job 容器默认挂 docker.sock**——自己再 `--container-options -v sock:sock` 就 `Duplicate mount point`；且 `--container-daemon-socket -` 会把 **workspace 复制也禁掉**（同走一个 socket）→ 容器里什么都没有。
4. **被测物必须在 workspace 内**：unit job 测的插件是 workspace 内的 `plugin/` 拷贝（主脚本 stage，gitignore 不入库）——act 的 workspace 是复制不是挂载，跨目录引用必空。

### 容器里装 cloudify 7.0.5 的三道闸

| 坑 | 解法 |
|:---|:---|
| PEP 668 externally-managed | `--break-system-packages`（CI 容器标准操作） |
| `cloudify==7.0.5` 只有 sdist，pip 自由解析会抓到老版本 cloudify-common 的 py2 语法 sdist | **显式钉** `cloudify-common==7.0.5` |
| sdist 构建拉 PyYAML sdist 撞 Cython 3（`cython_sources` 经典错误） | `PIP_ONLY_BINARY: "pyyaml,PyYAML"`（job 级 env，对 build isolation 也生效；只对 pyyaml 强制——cloudify 本体必须允许 sdist） |

镜像选 **python:3.11-slim**（act-latest 的 py3.12 与 cloudify 7.0.5 兼容问题连环；3.11 与本机 venv 同版本）。

### 门禁的两条红线（负向验证）

- bad-validate：`sed` 把 node type 写坏 → validate 必须非零退出（exp01 的负向事实进 CI）
- bad-unit：`sed` 把断言 200→999 → pytest 必须红
- 主脚本断言两者 act 退出码均非 0——"门禁真的会拦"本身是被测行为

## Pitfalls & Q&A

1. **act 输出的 job 名是空格 padding 的等宽表格**（`[blueprint-ci/unit         ]`）——断言匹配要 ` *`；且本机默认 grep 是 ugrep，行为与 BSD grep 有差异，断言用哪种要实测。
2. **cfy-lint 0.0.37 与新版 click 不兼容**（`get_fix() takes 2 positional arguments`）——lint 步骤 `|| true` 不设红（记录为已知限制，validate 才是闸门）。
3. **cryptography 被 debian 管理无法 pip 升级**（`RECORD file not found`）——`--ignore-installed cryptography`。
4. unit job 的 pytest 失败 21s（装包+跑）而不是秒退——**秒退几乎都是环境错（cwd/缺包），先看是不是 workspace 问题再怀疑测试本身**。
5. act 容器可能滞留（bad-* 的负向容器失败后偶尔不自动清）——residue 相对套件容器兜底清理再断言零残留。

## 产物清单

- `.github/workflows/{blueprint-ci,bad-validate,bad-unit}.yaml` + `bp.yaml`/`bad.yaml`/`scripts/create.sh`（01 的被测蓝图拷贝）
- `blueprint_ci.sh`：4 相 20 断言全绿（两遍）；被测插件拷贝由脚本 stage（gitignore）
