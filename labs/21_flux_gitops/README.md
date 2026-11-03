# 21 · Flux GitOps：声明 → 调谐 → 自愈（真 Git 推送回路）

> 集群状态由 git 声明：`git push` 即部署，手动改集群会被自动拉回——本实验跑通的是**真调谐回路**（Gitea 源 → GitRepository → Kustomization），不是 kubectl apply 的模拟。

## Background

Kubectl apply 是"推"：你执行一次，集群变一次，之后没人管。GitOps 把方向反过来——集群里常驻一个控制器（Flux），持续把**声明源**（git 仓库）同步到集群：源变了自动应用，集群被人手改了自动回正。生产中声明源是 GitHub/GitLab；本实验用靶场 Gitea（localhost:3300）承载同一套协议，模型完全一致。

## What

- `clusters/lab/`：声明源（ns demo + Deployment replicas=1 + Service）——**仓库里是什么样，集群就是什么样**
- `flux_gitops.sh` 五相：`apply`（Gitea 建仓 + push + flux install + GitRepository/Kustomization + 首次同步）/ `observe`（控制器、CRD、源与调谐状态）/ `push`（声明副本 1→2 → git push → Flux 自动跟上）/ `drift`（手动 scale 到 5 → Flux 自动回正）/ `clean`
- 靶场：kind `flux-lab` 集群（专用）+ 靶场 Gitea `devops/gitops` 仓库（脚本幂等建仓）

## When to Use

- 想理解 GitOps 与 CI 的区别：CI 是"事件触发一次部署"，GitOps 是"持续对账的期望态"
- 团队要落地"git 为唯一事实源"：回滚 = `git revert`，漂移 = 自动修复，审计 = git log
- 演示给团队看"为什么手动 kubectl 改集群是反模式"（drift 相有活证据）

## Quick Start

```bash
cd labs/21_flux_gitops
./flux_gitops.sh apply     # 全套就绪 + 首次同步（首次含镜像自救链，见 Pitfalls 1）
./flux_gitops.sh push      # git push → Flux 自动部署（副本 +1）
./flux_gitops.sh drift     # 手动 scale → 自动回正
./flux_gitops.sh clean     # 卸载 Flux（集群与仓库保留）
./flux_gitops.sh           # 或一次跑完全链
```

前置：flux CLI（2.9.x 已装）、kubectl、kind；靶场 Gitea 容器会被脚本自动拉起（admin/devops123，见 labs/05）。

## How It Works

### 两个 CRD 撑起整个模型

```yaml
GitRepository   # source-controller 每 15s 从 Gitea 拉取，打包成 artifact
Kustomization   # kustomize-controller 每 15s 取 artifact，path=./clusters/lab，
                # apply 进集群（prune: true → git 里删了集群里也删）
```

观察调谐：`flux get sources git` / `flux get kustomizations`（READY=True 且 REVISION 随每次 push 前进）。**push 相**（副本 1→2）与 **drift 相**（手动扩到 5 被拉回声明值）分别证明"正向同步"与"逆向自愈"两个方向。

### pod 内如何访问宿主的 Gitea

source-controller 在集群内，Gitea 在宿主 3300 端口。脚本动态取 **kind 网桥的 IPv4 网关**（`docker network inspect kind`，OrbStack 下是 v6 优先、必须按 Family 过滤）拼出 `http://<gw>:3300/...`；认证走 `git-auth` secret（username/password），GitRepository 的 `secretRef` 引用。

## Pitfalls & Q&A

1. **ghcr.io 控制器镜像在本网络会无限爬行**（层下载挂死、永不超时）。脚本内置自救链：NJU 镜像（ghcr.nju.edu.cn，502 是瞬时的、重试即可）预拉 → 重打 `ghcr.io` tag → `docker save | ctr 导入节点`（`kind load` 在 OrbStack 必踩 `digest not found`）→ **重启节点 containerd**（在途挂死拉取不重启不会让位）→ 重跑 install。demo 镜像 `python:3.12-slim` 同理由宿主导入（节点拉 docker.io 同样爬行）。
2. **`flux install` 没有 `--silent`**（uninstall 才有）——无效 flag 秒退再被 `|| true` 吞掉，看起来像"install 成功但 pod 不起来"，实为 install 根本没执行。
3. **`set -e` + `2>/dev/null` = 静默死**：集群不可达时 `kubectl get nodes 2>/dev/null` 失败、stderr 被吞、`set -e` 直接退出——旧脚本"打印一行就退出"就是这么来的。脚本现以显式探活 + fail 提示替代。
4. **`bash -c` 里不能用 shell 函数**（`kctx`/`fctx` 不被子进程继承）——等待断言改为在当前 shell `eval` 字符串。
5. **jsonpath 过滤器的引号易与外层冲突**（`[?(@.type=="Ready")]` 的双引号被外层吃掉）——断言行用单引号字面量 + `grep -qx True` 收口；`flux get` 表格的 READY 列是 `True/False`，grep `Ready` 永不命中。
6. **kind 网桥网关按 Family 取**：OrbStack 的 kind 网络 v6 优先，`IPAM.Config[0]` 是 v6，裸 IPv6 塞进 GitRepository URL 报 invalid port。
7. **repo 布局 = 集群布局**：seed 直接推 `clusters/` 目录树（Kustomization `path=./clusters/lab` 才能命中）；首次 seed 用 force push（工作副本的声明就是事实源）。

## 产物清单

- `flux_gitops.sh`：五相脚本（apply/observe/push/drift/clean），`all` 全链两遍验证
- `clusters/lab/{kustomization,demo}.yaml`：入 git 的声明源（仓库布局 = 集群布局）
- 运行时：`tmp/repo`（git 工作副本，tmp/ 已 gitignore）；靶场 `devops/gitops` 仓库与 kind `flux-lab` 集群保留可复用
