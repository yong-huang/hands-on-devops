# 24 · 密钥治理（SOPS + age）：密文入 git 与静态加密路线

> 密钥以**值加密、键名明文**的形态入 git（可 review、可 diff、可追溯），CI 持 age 私钥解密部署——与 labs/06 的 Vault 动态注入互为选型对照。

## Background

密钥治理的两条路线：**静态加密**（SOPS：密文进 git，消费端持钥解密）与**动态注入**（Vault：凭证不落盘，运行时租借）。本实验走完 SOPS 路线的完整生命周期——生成密钥、值级加密、三重泄漏扫描、CI 解密、git diff 友好性、密钥轮换三步曲——并给出选型矩阵。

## What

- `.sops.yaml`：`encrypted_regex` 只加密 `data/stringData/password/...` 的**值**——键名与结构明文，reviewer 看得见"哪个值变了"而看不到值
- `sops_age.sh` 六相：keygen（age 600）/ encrypt（三重泄漏扫描：工作区 grep、git log -p、git diff）/ deploy（CI 视角解密 → K8s Secret 生成，base64 解码断言）/ gitdiff（两版密文 diff）/ rotate（三步曲）/ matrix（SOPS vs Vault）
- 运行时产物全部在 `tmp/`（gitignore）：私钥、密文、git-probe——`clean` 后可由脚本完全重生成

## When to Use

- K8s 清单里的 Secret 需要进 git（GitOps 工作流：labs/21 的 Flux 拉的就是这种密文）
- 小团队、无 Vault 基建：零成本获得"密钥可审计（git log）+ 可回滚（git revert）+ 可协作（PR review 密文）"
- 不适用：多服务动态凭证、秒级 TTL、精细读取审计——那是 Vault 的地盘（见 matrix 相对比表）

## Quick Start

```bash
cd labs/24_sops_age
./sops_age.sh          # 六相 13 断言，两遍全绿
./sops_age.sh rotate   # 单独看密钥轮换三步曲
```

前置：sops 3.13 + age v1.3.2（本机已装）。

## How It Works

### 值级加密（encrypted_regex）

```yaml
creation_rules:
  - path_regex: secrets/.*\.yaml$
    encrypted_regex: '^(data|stringData|password|username|endpoint|token)'
    age: age1xxxx
```

默认全字段加密（连 apiVersion 都变密文）；加 `encrypted_regex` 后只有匹配的**值**加密——`git diff` 里键结构明文、值逐行变密文，reviewer 无需解密即可判断"改了哪个字段"。

### 密钥轮换三步曲（sops rotate 子命令）

```bash
sops rotate -i --add-age <新公钥>   # ① 新旧并存：两把钥匙都能解（迁移窗口）
sops rotate -i --rm-age  <旧公钥>   # ② 移除旧钥：旧 key 立即失效
```

数据加密密钥（DEK）不变、只有 master key 元数据变化——**存量密文无需重写**。rotate 相逐相断言：并存期双钥可解 → rm 后旧钥失效 → 终态新钥全权解密。

### CI 视角

`deploy` 相只持一个文件 `tmp/key.txt`（`SOPS_AGE_KEY_FILE` 指定）：解密 → 生成 K8s Secret 产物（base64 解码断言原值）——产物即 kustomize/flux 的部署输入（衔接 labs/21）。

## Pitfalls & Q&A

1. **`.sops.yaml` 的 `path_regex` 相对仓库根**：模拟 git 仓库时 `.sops.yaml` 必须随仓库走，文件保持 `secrets/` 目录布局——路径对不上报 `no matching creation rules found`。
2. **`sops --rotate` 不存在**：轮换是**子命令** `sops rotate`，flag 是 `--add-age`/`--rm-age`（按公钥指纹操作）；`--age` 只是 encrypt 时的 flag。
3. **age recipient 是从私钥文件里 grep 出来的**——手抄极容易错一个字符（实测：编造的 recipient 报 `invalid checksum`），永远从 `key.txt` 现取。
4. **`kubectl create secret` 产物是 base64 `data:` 形态**：断言原值要解码，别直接 grep 明文。
5. **grep 管道的退出码**：`git diff | grep '不存在模式'` 无匹配即 rc=1，`set -e` 下静默中断——管道首段模式要保证匹配（本实验的 diff 里 `stringData:` 行是上下文行，没有 +/- 前缀）。
6. **`.sops.yaml` 的 creation_rules 首个匹配即生效**：手抄 recipient 到配置前先想清楚——错 key 加密成功但 decrypt 时 key 不匹配（实测文件损毁一次，教训：recipient 一律现取）。

## 产物清单

- `.sops.yaml`（encrypted_regex + age recipient）+ `secrets/db-credentials.yaml`（运行时，密文形态示范）
- `sops_age.sh`：六相 13 断言全绿（两遍）；`tmp/`（gitignore）含私钥/git-probe
- 选型矩阵（matrix 相）：模型/事实源/解密位置/轮换/审计/基建成本/适用六维对照 SOPS 与 Vault
