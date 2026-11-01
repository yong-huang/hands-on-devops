#!/usr/bin/env python3
"""semi/02_org_guard · 组织与 IP 保护的 API 侧 bootstrap（幂等，读 configs/org.yaml）。

用法：bootstrap_org.py <url> <root_token> <org.yaml>
职责：建组树 → 建用户 → 挂成员 → 建项目 → 保护分支 → 空仓库时用 commits API 写首提交。
      commits API 走 web 通道（写文件），对受保护分支按"允许合并"鉴权，Owner 可写，
      不经过 git push / server hook——与 verify 里的真实 git push 形成完整对照。
"""
import sys

import gitlab
import yaml

url, token, org_file = sys.argv[1], sys.argv[2], sys.argv[3]
spec = yaml.safe_load(open(org_file))
gl = gitlab.Gitlab(url, private_token=token)
gl.auth()
print(f"[ok] 管理员身份：{gl.user.username}")

# ── 组树：自上而下，path 相对父组 ──────────────────────────────────────
group_ids: dict[str, int] = {}
parent_full = None
for g in spec["groups"]:
    parent_id = group_ids.get(parent_full)
    full_path = f"{parent_full}/{g['path']}" if parent_full else g["path"]
    try:
        created = gl.groups.create(
            {"path": g["path"], "name": g["name"], "parent_id": parent_id}
        )
        print(f"[ok] 建组 {full_path}")
    except gitlab.exceptions.GitlabCreateError:
        created = gl.groups.get(full_path)
        print(f"[  =] 组已存在 {full_path}")
    group_ids[full_path] = created.id
    parent_full = full_path

design_full = "semi/ip/design"
design = gl.groups.get(design_full)

# ── 用户 ─────────────────────────────────────────────────────────────
user_ids: dict[str, int] = {}
for u in spec["users"]:
    found = gl.users.list(username=u["username"])
    if found:
        user_ids[u["username"]] = found[0].id
        print(f"[  =] 用户已存在 {u['username']}")
    else:
        created = gl.users.create(
            {
                "username": u["username"],
                "name": u["name"],
                "email": u["email"],
                "password": u["password"],
                "skip_confirmation": True,   # 实验用户免邮件确认
            }
        )
        user_ids[u["username"]] = created.id
        print(f"[ok] 建用户 {u['username']}")

# ── 成员矩阵 ─────────────────────────────────────────────────────────
for g in spec["groups"]:
    full_path = "/".join(x["path"] for x in spec["groups"][: spec["groups"].index(g) + 1])
    grp = gl.groups.get(full_path)
    for m in g.get("members", []):
        try:
            grp.members.create(
                {"user_id": user_ids[m["username"]], "access_level": m["access_level"]}
            )
            print(f"[ok] {m['username']} → {full_path} (level {m['access_level']})")
        except gitlab.exceptions.GitlabCreateError:
            print(f"[  =] 成员已在 {full_path}: {m['username']}")

# ── 项目 + 保护分支 + 首提交 ──────────────────────────────────────────
for p in spec["projects"]:
    project_full = f"{design_full}/{p['path']}"
    try:
        proj = gl.projects.create(
            {"path": p["path"], "name": p["name"], "namespace_id": design.id}
        )
        print(f"[ok] 建项目 {project_full}")
    except gitlab.exceptions.GitlabCreateError:
        proj = gl.projects.get(project_full)
        print(f"[  =] 项目已存在 {project_full}")

    for pb in p.get("protected_branches", []):
        names = [b.name for b in proj.protectedbranches.list(get_all=True)]
        if pb["name"] in names:
            print(f"[  =] 保护分支已存在 {project_full}:{pb['name']}")
        else:
            proj.protectedbranches.create(
                {
                    "name": pb["name"],
                    "push_access_level": pb["push_access_level"],
                    "merge_access_level": pb["merge_access_level"],
                    "allow_force_push": False,
                }
            )
            print(
                f"[ok] 保护分支 {pb['name']}：push={pb['push_access_level']}(No access) "
                f"merge={pb['merge_access_level']}(Maintainer)"
            )

    if proj.attributes.get("empty_repo"):
        proj.commits.create(
            {
                "branch": p["initial_branch"],
                "commit_message": "init: push-lab 靶场仓库（bootstrap_org.py）",
                "actions": [
                    {
                        "action": "create",
                        "file_path": p["initial_file"],
                        "content": f"# {p['name']}\n\n组织与 IP 保护实验的 push 验收靶场。\n"
                        "受保护 main 只许走 MR；大文件走 LFS（平台 pre-receive 拦截）。\n",
                    }
                ],
            }
        )
        print(f"[ok] 首提交写入 {project_full}:{p['initial_branch']}（commits API）")
    else:
        print(f"[  =] 仓库非空，跳过首提交 {project_full}")

print("[ok] 组织 bootstrap 完成")
