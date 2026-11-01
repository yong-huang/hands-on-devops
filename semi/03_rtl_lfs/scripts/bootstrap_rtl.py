#!/usr/bin/env python3
"""bootstrap_rtl.py —— 建 semi/ip/design/rtl-gcd 项目（幂等）。

与 push-lab 的差异：这是后续 20 个项目的 SUT，CI（root 身份）要直推 tag/分支，
所以 main 保护降为 push=40（Maintainer 可直推、dev1 无权），不再禁一切直推。
仓库保持空——内容全部由 git push 灌入（LFS 对象必须走真实 push 通道）。
"""
import sys

import gitlab

url, token = sys.argv[1], sys.argv[2]
gl = gitlab.Gitlab(url, private_token=token)
gl.auth()
print(f"[ok] 管理员身份：{gl.user.username}")

design = gl.groups.get("semi/ip/design")
full = "semi/ip/design/rtl-gcd"
try:
    p = gl.projects.create(
        {
            "path": "rtl-gcd",
            "name": "RTL-GCD 载体",
            "namespace_id": design.id,
            "default_branch": "main",
            "description": "半导体 CI/CD 清单 SUT：GCD IP（RTL/TB/sim/docs + PDK/GDS/波形假大文件）",
        }
    )
    print(f"[ok] 建项目 {full}")
except gitlab.exceptions.GitlabCreateError:
    p = gl.projects.get(full)
    print(f"[  =] 项目已存在 {full}")

names = [b.name for b in p.protectedbranches.list(get_all=True)]
if "main" not in names:
    p.protectedbranches.create(
        {
            "name": "main",
            "push_access_level": 40,    # Maintainer 可直推：CI/发布以 root 身份推 tag 与分支
            "merge_access_level": 40,
            "allow_force_push": False,
        }
    )
    print("[ok] 保护分支 main：push=40(Maintainer) merge=40(Maintainer)")
else:
    print("[  =] 保护分支 main 已存在")

print(f"[ok] rtl-gcd 就绪（empty_repo={p.attributes.get('empty_repo')}）")
