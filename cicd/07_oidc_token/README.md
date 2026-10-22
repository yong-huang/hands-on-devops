# 07 · OIDC 短时凭据——干掉长期 secret

> 传统 CI 的做法是在 GitHub Secrets 里存一个长期 Access Key——泄露了就是
> 全权凭证。OIDC（OpenID Connect）换一种思路：CI runner 向 GitHub 索取一张
> 短时效 JWT（有效期约 1 小时），本地用 JWKS 公钥验签确认真实性。没有长期
> secret 可泄露，token 过期自动作废。

## Background

labs/14（cosign/syft）管住了"制品侧"的签名与扫描，但"流水线侧"的凭据安全
长期依赖 GitHub Secrets 存放长期凭证。这些凭证一旦泄露（日志打印、fork PR
注入、runner 被入侵），攻击者就拿到了云资源的完全控制权。

OIDC 换一种思路：runner 在执行 job 时向 GitHub 服务端索取一张短期 JWT
（JSON Web Token），token 的 `sub` claim 写明"是哪个仓库的哪个分支触发的"，
云厂商验签后按条件发放临时凭证——长期 secret 完全不需要存在。

本实验做 OIDC 的前半段：runner 签发 token → artifact 化 → 本地 JWKS 验签
→ claims 断言 → 篡改反例。后半段（token 换云厂商临时凭证）需要云账号，
选做。

## What

**定义**：OIDC token 是 GitHub 服务端签发的 JWT（JSON Web Token，一种自
包含的签名令牌），`permissions: id-token: write` 是获取它的唯一开关。

| 部件 | 角色 |
|:---|:---|
| `permissions: id-token: write` | 告诉 GitHub：这个 job 需要 OIDC token |
| `ACTIONS_ID_TOKEN_REQUEST_URL` | GitHub 的 OIDC 签发端点（token 获取入口） |
| `token.actions.githubusercontent.com` | GitHub OIDC 的 issuer（签发者） |
| JWKS（JSON Web Key Set） | 签发者的公钥集合——本地用它验签 |
| `claims` | JWT payload 里的字段：repository / ref / actor / aud |

可以把 OIDC token 想象成一张限时通行证：每过一道门（job）都要重新领一张，
证上写着你的身份（repository / actor）和有效期（exp），门卫（JWKS 验签）
核对签名后才放行。失效边界：通行证只证明"你从哪个仓库来"，不授权你做任何
具体操作——授权需要云厂商根据 claims 做二次映射。

## When to Use

- CI 需要访问云资源（AWS/GCP/Azure）但不想存长期 Access Key；
- 多租户场景：每个仓库的 token 只能访问自己的资源（claims 隔离）；
- 安全审计：没有长期凭证可泄露，攻击面从"永久"缩小到"1 小时"。
- 反例：不需要访问外部资源的纯构建/测试流水线——OIDC 增加了理解成本。
- 本实验不含"OIDC → 云厂商临时凭证"（需要云账号，选做）。

## Quick Start

前置：gh CLI（已登录）、python3（需 `cryptography` 库：pip install
cryptography）、公共仓库 `yong-huang/cicd-lab`。

```bash
cd cicd/07_oidc_token
./oidc_token.sh           # 完整生命周期：push → wait → download → verify → tamper → clean
./oidc_token.sh push      # 推 workflow 到真仓库
./oidc_token.sh wait      # 等待 run 完成
./oidc_token.sh download  # 下载 artifact 到本地
./oidc_token.sh verify    # JWKS 验签 + claims 断言
./oidc_token.sh tamper    # 篡改 payload → 验签失败（反例取证）
./oidc_token.sh clean     # 清临时文件
```

验签脚本的取证（本地输出）：

```
[1] 拉取 JWKS …
    4 个公钥
[2] 验证 RS256 签名 …
[3] 解码 claims …
    repository: yong-huang/cicd-lab
    ref:        refs/heads/main
```

回归加固（2026-10-20）：workflow 文件已补 `name:` 字段（无 name 时
display name 退化为文件路径，脚本按名字匹配 run 会全部落空）；run 查询
的 per_page 从 10 提到 40——仓库 run 变多后旧 run 会被挤出首页。

诚实预期：GitHub 平台侧的 workflow 运行有已知限制（run 名显示为文件路径且
秒失败）——本实验的核心学习成果是本地 JWKS 验签脚本，它不依赖 GitHub
平台（可独立验证任何 GitHub 签发的 OIDC token）。

## How It Works

### workflow：签发 token

```yaml
permissions:
  id-token: write   # 唯一开关
steps:
  - name: Fetch OIDC token
    env:
      REQUEST_URL: ${{ ACTIONS_ID_TOKEN_REQUEST_URL }}
      REQUEST_TOKEN: ${{ ACTIONS_ID_TOKEN_REQUEST_TOKEN }}
    run: |
      RESP=$(curl -s -H "Authorization: Bearer $REQUEST_TOKEN" "$REQUEST_URL")
      TOKEN=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
```

`id-token: write` 让 GitHub 在 runner 环境里注入 `ACTIONS_ID_TOKEN_REQUEST_URL`
和 `ACTIONS_ID_TOKEN_REQUEST_TOKEN` 两个环境变量。

用 curl 向该 URL 发请求（带请求 token 作为认证），GitHub 返回签发的 JWT。

### 本地验签：JWKS 公钥核对签名

```python
header_b64, payload_b64, sig_b64 = token.split(".")
header = json.loads(b64url_decode(header_b64))
kid = header["kid"]          # 用哪把公钥签的

# 从 JWKS 找到匹配的公钥 → 转 PEM → 验证 RS256 签名
pub_key.verify(signature, signing_input, padding.PKCS1v15(), hashes.SHA256())
```

JWT 的三段（header / payload / signature）都是 base64url 编码。

签名验证用的是 JWKS 里的 RSA 公钥（按 `kid` 匹配）——私钥在 GitHub 服务
端，本地只有公钥，因此无法伪造 token。

### 篡改反例：改一个字符，验签立刻失败

payload 的最后一个字节翻转后，签名不再匹配（RS256 是密码学安全的签名算法
——改变输入的任何一位，签名验证都会失败）。这就是"篡改检测"的原理。

## Pitfalls & Q&A

- **① act 不支持 OIDC**：act 0.2.89 没有 `id-token: write` 的模拟——
  `ACTIONS_ID_TOKEN_REQUEST_URL` 为空。必须推真仓库。
- **② aud 参数必须传**：不传 audience 时 GitHub 也能签发，但 `aud` claim
  为空——某些云厂商验签时会因缺少 aud 而拒绝。
- **③ base64url 不是标准 base64**：JWT 用 base64url（`-` 代替 `+`，`_`
  代替 `/`，去掉 padding `=`），解码时需要转换。

Q&A：

- **OIDC token 和 GitHub token（ghp_xxx）有什么区别？** ghp_xxx 是个人访问
  令牌（长期、全权限）；OIDC token 是 job 级的短时效 JWT（1 小时、claims
  限定范围、由 GitHub 签发）。前者泄露了要手动撤销，后者过期自动作废。
- **本地能伪造 OIDC token 吗？** 不能：签名用 GitHub 的 RSA 私钥（不在
  JWKS 里），篡改 payload 任何一位都会导致验签失败（本实验的反例取证）。
- **什么是"OIDC → 云厂商换临时凭证"？** token 给云厂商（如 AWS STS
  AssumeRoleWithWebIdentity），云厂商验签后按 IAM Role 的 trust policy
  发放临时凭证——这就是"keyless"部署。本实验不含（需要云账号）。
