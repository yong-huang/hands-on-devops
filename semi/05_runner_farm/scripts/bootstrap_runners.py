#!/usr/bin/env python3
"""bootstrap_runners.py —— 用管理员 API 签发 glrt- 认证令牌（GitLab 16+ 新流程）。

老教程里的 registration token 已在 16.0 移除；现在先 POST /user/runners 建实例级 runner，
响应里拿一次性 glrt- 令牌，塞进 runner 的 config.toml 即完成"注册"。幂等：同名 runner
已存在则先 DELETE 再建，保证每次 up 都拿到新鲜 token。
"""
import sys

import gitlab

gl = gitlab.Gitlab(sys.argv[1], private_token=sys.argv[2])
specs = [("runner-eda", "eda", 2), ("runner-fpga", "fpga", 1)]

for name, tag, _conc in specs:
    # ⚠️ 清理必须走 /runners/all：GET /runners 对 admin 也有可见性过滤（实测返回空），
    #    用它找旧 runner 会漏删 → 同名 runner 越积越多，config.toml 里的 token 还是旧的
    for r in gl.http_get("/runners/all", query_data={"per_page": 100}):
        if r["description"] == name:
            gl.runners.delete(r["id"])
            print(f"[  =] 删旧 runner {name}#{r['id']}")
    # python-gitlab 的 runners.create 走旧注册端点（要 registration token，已废除）——
    # 新流程必须裸 POST /user/runners 拿 glrt- 认证令牌
    created = gl.http_post(
        "/user/runners",
        post_data={
            "runner_type": "instance_type",
            "description": name,
            "tag_list": tag,
            "run_untagged": False,
            "locked": False,
        },
    )
    print(f"[ok] {name} id={created['id']} tags=[{tag}] token={created['token'][:12]}…")
    print(f"TOKEN:{name}:{created['token']}")
