# 18 · 制品治理：bitstream 版本化 + cosign 签名 + 不可变纪律

> 清单：[docs/cicd-semi.md](../../docs/cicd-semi.md) 项目 18 · 阶段五「构建、制品与发布」
> Generic Packages 版本化 bitstream 三件套（bin+manifest+签名）/ cosign 签名验签 / 不可变守卫
> 验收在 `artifacts.sh verify`：发布+三重校验 / 同版本重复发布被拒，全过打 `[ok]`

## Background

FPGA 流水线产出的 bitstream 是"要交付的硬件"——谁构建的、内容是什么、有没有被篡改，必须可证明。

治理三件套：**版本化**（Generic Packages，版本号即不可变坐标）、**清单**（MANIFEST.sha256 固定内容）、**签名**（cosign sign-blob，私钥签/公钥验）。核心纪律只有一条：**制品不可变**——同版本号永不允许覆盖，改了就发新版本。

## What

心智模型一句话：**版本号是承诺，签名是公证，守卫是法律**。

| 文件 | 作用 |
|:---|:---|
| top.bin | 比特流本体（P17 流水线的产物） |
| MANIFEST.sha256 | 内容指纹（消费端对账） |
| top.bin.sig | cosign 签名 bundle（私钥签发，公钥可验） |

验证方法：`./artifacts.sh verify`——发布新版本 → 消费端下载/sha256/验签三重校验 → 同版本重发被拒。

## When to Use

| 场景 | 做法 |
|:---|:---|
| CI 产出的可交付物版本化 | Generic Packages（本实验）——无需额外存储设施 |
| 防篡改与来源证明 | cosign sign-blob（密钥对本地上签，离线可验） |
| 防"顺手覆盖" | 发布脚本内置不可变守卫（先探测后上传） |
| 消费端验证 | verify_artifact.sh 三重校验，可独立分发 |

## Quick Start

前置：项目 17 完成（bitstream 在流水线产物里）、cosign（brew install cosign）。

```bash
./artifacts.sh up      # 推 artifacts job + 注入 CI/CD 变量 GITLAB_PAT（masked+protected）
./artifacts.sh verify  # 发布 → 三重校验 → 不可变拒绝（约 2 分钟）
./artifacts.sh status  # Packages 清单
./artifacts.sh clean   # 删演示包
```

`verify` 的真实输出（实测，全过）：

```
=====> [publish] 发布 v1793496647（先查后传 + cosign 签名）
  [ok]   发布成功（bitstream+manifest+signature）
=====> [verify1] 消费端三重校验（下载/sha256/cosign）
  [ok]   [verify] sha256 一致：b97510efeca0f5c7… [verify] cosign 验签通过
=====> [verify2] 不可变纪律：同版本重复发布被拒
  [ok]   同版本二次发布被守卫拒绝（exit≠0 + 提示换版本号）

[ok] 项目 18 全部验收断言通过
```

## How It Works

### 不可变守卫探测制品文件本身

"版本已存在"的判定不能用 `packages?version=` 列表过滤——实测该参数被忽略（按包名命中即误报）。守卫直接 HEAD/GET 制品文件 URL：200 即已存在。制品文件的存在性才是"版本已发布"的定义。

### CI job 的鉴权：masked+protected 的 PAT

Generic Packages 上传鉴权用 PAT（GITLAB_PAT）注入为 CI/CD 变量，masked（日志不打明文）+ protected（仅 protected ref 可读）。

更优解是 CI_JOB_TOKEN + 包权限白名单（P6 已验证过该机制），本实验保留 PAT 路线以覆盖"跨项目强权限"场景。

## Pitfalls & Q&A

**坑 1：cosign 3.x 的三个新语义。** ① sign-blob 默认新 bundle 格式：签名落 `--bundle` 文件而非 stdout。

② `--tlog-upload=false` 已废弃，被 `--signing-config` 取代——离线场景先 `cosign signing-config create` 生成无 tlog 配置。

③ 另外 `yowasp-icestorm` 这个包名并不存在——icepack 工具内置于 yowasp-nextpnr-ice40 包。同类"想当然的包名"都要实测。

③ 另外 `yowasp-icestorm` 这个包名并不存在——icepack 工具内置于 yowasp-nextpnr-ice40 包。

同类"想当然的包名"都要实测。

**坑 2：pipefail + grep -q 的 SIGPIPE 误判。** `bash 发布脚本 | grep -q 关键词`——grep 匹配后即退出，发布脚本继续写日志吃 SIGPIPE(141)，pipefail 把整条管道判非零，"拒绝"测试反而失败。

修法：命令输出落临时文件再 grep（不共享管道）。

**坑 3：generic 包下载 404。** 发布被守卫拒绝后版本不存在，消费端 404 是正常的——三个失败往往是同一个根因的级联（publish 失败 → verify 404 → 不可变测试又"通过"了错误的路径）。排障先看第一个失败。

**Q：为什么制品挂在 eda-base 项目而不是 rtl-gcd？** 与 P6 的镜像同理：制品的消费者（量产/测试组）与生产者（设计组）分离，独立项目 + 显式授权是治理边界。P19 的 Release 会挂回 rtl-gcd 引用这些制品。