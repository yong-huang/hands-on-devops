# 13 · Registry 治理：认证、GC 与保留策略

> registry 用起来就是个"docker push 的目标"，但它本质是个存储生产组件：谁都能推？
> 删掉的镜像真释放空间了吗？三年不清理会膨胀成什么样？本实验给 registry 加上认证、
> 删除接口、GC 与保留策略脚本，并用 5MB 独立层实测回收效果。

## 1. 为什么需要它

裸 `registry:2` 的默认形态有三个隐患：

- **匿名读写**：任何能碰到端口的人都能推镜像（供应链攻击入口）；
- **只进不出**：没开 delete 就不能删，开了 delete 也要 GC 才真正回收——
  API 删除只是"账本上划掉"，blob 还躺在磁盘里；
- **无保留策略**：CI 每天推 20 个 tag，一年 7000 个，拉取列表越来越长、磁盘越来越爆。

## 2. 总览：核心机制一图看懂

![registry governance](images/registry_governance.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-devops/labs/13_registry_governance/images/registry_governance.html)
> （或本地打开 [`images/registry_governance.html`](images/registry_governance.html)）。

看图方法：匿名请求被 401 拒绝（security 线）；登录客户端走 Basic 认证推拉；
删除/GC 沿 storage 路径回收 blob。GC 需要停写、先删 manifest 再跑 mark-sweep。

## 3. 快速开始

```bash
cd labs/13_registry_governance
./registry_governance.sh            # auth → gc → retain → clean
./registry_governance.sh gc         # 单独看删除+回收量化
```

真实输出（关键节点）：

```
=====> [auth] 带认证的 registry：匿名 401，登录后推拉
        401
        [ok] 登录成功
        [ok] 推拉链路通（认证生效）
=====> [gc] 删除 v2 → GC → 磁盘占用前后对比
        GC 前：19.5MB
        DELETE tag(index) → 202
        DELETE child manifest → 202   ×2
        GC 后：14.4MB                 # 正好回收 5MB 独立数据层
=====> [retain] 保留策略：demo/app 只保留最近 2 个 tag
        [ok] 保留策略即代码
```

## 4. 核心概念

### 4.1 认证：htpasswd 只认 bcrypt

```bash
htpasswd -Bbn devops regpass123 > auth/htpasswd   # -B = bcrypt，必选
```

registry 的 htpasswd 认证只接受 bcrypt（-B）；MD5/明文会直接拒绝启动。
docker login 之后凭据以 base64 存在 `~/.docker/config.json`——它是"便利缓存"而非保险箱。

### 4.2 删除与 GC 是两步

- `DELETE /v2/<name>/manifests/<digest>`（202）：只删 manifest 记录，blob 仍在；
- `registry garbage-collect config.yml`：mark-and-sweep 真正回收无人引用的 blob。

两个关键细节：删除的键是 **manifest digest**（响应头 `Docker-Content-Digest`，不是
config 的 digest）；buildx 推的镜像 tag 指向 **OCI index**，还要把 index 里的
子 manifest 逐个 DELETE，否则 5MB 数据层仍被引用、GC 收不回。本实验实测：
删干净后 GC 19.5MB → 14.4MB。生产守则：GC 放维护窗口、先停写（或用只读模式）。

### 4.3 保留策略即代码

脚本演示 keep=2：列 tag → 语义化版本排序 → 超期的按 digest 删除。
生产规则通常是：`prod/*` 豁免 + 每仓库保留最近 N 个 + main 分支构建永久保留。
把这段脚本放进 CI 定时任务，registry 就永远不会"悄悄膨胀"。

## 5. 配置关键字段

```yaml
storage:
  filesystem: { rootdirectory: /var/lib/registry }
  delete: { enabled: true }        # GC 与 API 删除的前提
auth:
  htpasswd: { realm: basic-realm, path: /auth/htpasswd }
http:
  addr: :5000                      # 提供了配置文件就必须显式声明监听地址！
```

坑清单（全部真实踩过）：

- **坑① 给了 config.yml 却没写 http.addr**：registry 只听容器内 127.0.0.1，
  端口映射后所有请求 Connection reset；
- **坑② manifest 404**：buildx 推的是 OCI index，Accept 头必须带
  `application/vnd.oci.image.index.v1+json`，只写 docker v2 类型会 404；
- **坑③ DELETE 400**：键错了——要用响应头 Docker-Content-Digest（manifest digest），
  不是 manifest JSON 里 config 的 digest；
- **坑④ GC 收不回数据层**：只删 index 不删子 manifest，blob 仍被引用（本实验实测 0.1MB→5MB 的差距）。

## 6. 文件结构

```
13_registry_governance/
├── README.md                    # 本教程
├── registry_governance.sh       # auth / gc / retain / clean
├── config/config.yml            # registry 配置（认证+删除+监听）
├── auth/htpasswd                # 运行时生成（bcrypt）
└── images/                      # 图三件套（json/html/svg）
```

## 7. 深入要点

- **registry 的 GC 为什么要停写？** GC 是 mark-and-sweep：写并发可能让"正在上传的
  blob"被误回收。生产用只读模式或维护窗口；云厂商托管 registry（GCR/ACR）替你处理。
- **API 删除和 GC 的关系？** API 删 manifest=标记不可达；GC=物理回收 blob。
  不开 delete.enabled 时连 API 删除都不存在。
- **镜像保留策略怎么设计？** 按标签语义分层：release 永久、main 最近 N 个、
  feature 分支按天数；策略脚本化进 CI 定时任务并 review。
- **私有 registry 的供应链安全？** 认证 + TLS + 内容信任（cosign 签名，实验 14）+
  SBOM（syft）+ 漏洞扫描（trivy）四位一体；匿名可写的 registry 是供应链攻击首选入口。

## 8. 总结

registry 从"能推能拉"升级为"认证 + 可回收 + 有策略"的治理态。实验 14 给制品再加
两份"身份证"：SBOM 说明里面有什么，cosign 签名证明它出自谁、没被篡改。
