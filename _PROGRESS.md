# 系列进度与阶段自检记录

> 配套 devops.md（30 项目清单）。本文件记录每个阶段完成时的真机自检结果，
> 是"每个实验都真实跑过"的证据链。

## 阶段二自检（实验 06-10 · 配置管理四大代际）· 2026-09-08

- [x] `bash -n` 全部通过；5 个主演示脚本全流程 exit=0（真机执行）
- [x] 实验 06 Ansible：动态清单发现 lab-nginx → role 首跑 changed=1 →
      二跑 changed=0 → 手工破坏自愈 → Vault 密文无明文/容器渲染命中/轮换成功
- [x] 实验 07 Molecule：`molecule test` 12 步 failed=0；
      故意写坏端口 → verify 断言红（failed=1）→ 修复回绿 → 测试容器零残留
- [x] 实验 08 Salt：masterless state.apply 首跑 changed=3 → 二跑零变更 →
      grain env=staging 切换 pillar → HTTP 内容自动切换（hello from STAGING）
- [x] 实验 09 Chef+InSpec：converge 后 InSpec 4 过 1 败（webapp-05 server_tokens）→
      修模板重收敛 → 5/5 全绿（退出码 100→0 的门禁语义）
- [x] 实验 10 Puppet：parser validate → apply 收敛（含依赖级联失败的真实演示）→
      `--detailed-exitcodes` 幂等 exit=0 → facter/resource 反向查询
- [x] 图三件套 30 张中的 10 张：全部过 showcase 九项门禁 + 四视口零溢出 + SVG 像素居中
      （02 号图质心 +7.1%、08 号 -7.4%、10 号 +6.1% 为内容固有形变，留白对称 ≤0.2pp，
      按规范接受并如实记录）
- [x] 环境对抗真实记录（详见各实验 README 坑清单）：
      - chef/chef 官方镜像 arm64/amd64 双损坏（alpine+glibc ruby）→ debian+omnitruck deb
      - puppetserver 镜像拉取失败（镜像源 EOF）→ 按清单预案降级 puppet apply
      - molecule docker driver 需要 bash（alpine 无）→ python:3.12-slim
      - ansible 清单插件文件名必须 *.docker.yml + enable_plugins 显式启用
      - bash 变量后接全角字符 → unbound variable（须 ${var} 隔离）
      - 容器内 wget localhost 走 IPv6 被拒 → 统一 127.0.0.1
- [x] clean 后零残留断言全过（靶场四件套属实验 05 管理，保持运行）

## 阶段一自检（实验 01-05 · Terraform 深水区 + 靶场）· 详见 labs/05 README 末尾

- [x] 01-05 全流程真机跑通（apply/observe/drift/lock/clean 各具特色断言）
- [x] 漂移检出、锁互斥、敏感值明文取证均真实触发
- [x] provider 离线镜像（scripts/tfrc.sh）+ socket 探测（scripts/docker-env.sh）

## 阶段三自检（实验 11-15 · 镜像与制品）· 2026-09-08

- [x] 11 瘦身：full 386MB / multistage 50MB / distroless 18MB（真实 inspect 数据），
      三版 HTTP 冒烟 200；dive CI 效率判定 PASS；buildx amd64+arm64 推 :5500，
      manifest list 双平台确认
- [x] 12 Packer：docker builder → ansible provisioner（docker 连接）→ tag+push；
      registry tags ["1.0.0","latest"]；拉取冒烟 healthz 200
- [x] 13 Registry 治理：htpasswd 认证（匿名 401）；API 删除 tag index + 子 manifest
      （202×3）→ GC 实测 19.5MB → 14.4MB（正好回收 5MB 独立层）；保留策略脚本化
- [x] 14 SBOM+签名：syft SPDX 25 包；cosign 签名/验签通过；同 tag 覆盖攻击 →
      verify exit=10 红灯
- [x] 15 发布流水线：make release VERSION=1.2.3 六步全通；artifacts/release-1.2.3.txt
      追溯清单落盘（digest+SBOM 校验和+签名 tag+冒烟时间）；clean 零残留
- [x] 图三件套 15 张累计：全部 showcase 门禁 + 视口检查 + SVG 像素居中
- [x] 环境对抗记录：packer 插件走 hashicorp CDN 可装（GitHub 不可达不影响）；
      packer ansible 插件新参数名 playbook_file；docker exec 环境变量必须 -e；
      registry OCI index 的 Accept/删除语义；bash 全角字符粘变量名（本阶段三次踩到）
