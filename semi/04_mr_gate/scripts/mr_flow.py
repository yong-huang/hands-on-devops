#!/usr/bin/env python3
"""mr_flow.py —— 第一个 MR 走通评审流（清单项目 4 验收①）。

dev1（Developer）：推 feature 分支（小文件，平台门禁应放行）→ 用自己的 PAT 开 MR
root（Maintainer）：approve → merge
断言：merge 后 main HEAD 变更，且审批记录 non-empty。
作者必须是 dev1：GitLab 规定 MR 作者不能审批自己的 MR，root 自开自合会让审批流失去意义。
"""
import subprocess
import sys
import tempfile
import time

import gitlab

URL = "http://localhost:28200"
root_token, dev1_token, dev1_pwd = sys.argv[1], sys.argv[2], sys.argv[3]
FULL = "semi/ip/design/rtl-gcd"

gl_root = gitlab.Gitlab(URL, private_token=root_token)
gl_dev1 = gitlab.Gitlab(URL, private_token=dev1_token)
project = gl_root.projects.get(FULL)

head_before = project.commits.get("main").id
print(f"[  =] merge 前 main HEAD：{head_before[:12]}")

# ── 1. dev1 推 feature 分支（真实 git push，小文件走门禁放行通道）────────
work = tempfile.mkdtemp(prefix="mr_flow_")
clone_url = f"http://dev1:{dev1_pwd}@localhost:28200/{FULL}.git"
subprocess.run(["git", "clone", "-q", clone_url, work], check=True)
branch = f"feature/hello-mr-{int(time.time())}"
subprocess.run(["git", "-C", work, "checkout", "-qb", branch], check=True)
greeting = f"docs/mr_greeting_{int(time.time())}.md"   # 唯一路径：重跑不复现 add/add 冲突
with open(f"{work}/{greeting}", "w") as f:
    f.write(f"# 来自 MR 的问候\n\n第一个评审流 MR（{branch}）——由 mr_flow.py 自动创建。\n")
subprocess.run(["git", "-C", work, "add", "-A"], check=True)
subprocess.run(["git", "-C", work, "-c", "user.name=dev1", "-c", "user.email=dev1@semi.local",
                "commit", "-qm", f"docs: 第一个 MR 的问候文件（{greeting}）"], check=True)
subprocess.run(["git", "-C", work, "push", "-q", "origin", branch], check=True)
print(f"[ok] dev1 推送分支 {branch}（门禁放行）")

# ── 2. dev1 开 MR（作者=dev1，root 才有资格审批）────────────────────────
mr = gl_dev1.projects.get(FULL).mergerequests.create(
    {
        "source_branch": branch,
        "target_branch": "main",
        "title": "docs: 第一个 MR——评审流集成验证",
        "description": "清单项目 4 验收①：分支 → MR → approve → merge 全 API 自动走通。",
        "remove_source_branch": True,
    }
)
print(f"[ok] dev1 开 MR !{mr.iid}（等 GitLab 计算 merge_status）")
for _ in range(30):
    mr = gl_dev1.projects.get(FULL).mergerequests.get(mr.iid)   # 每轮刷新，merge_status 是属性
    if mr.merge_status == "can_be_merged":
        break
    time.sleep(2)
mr = gl_dev1.projects.get(FULL).mergerequests.get(mr.iid)

# ── 3. root 审批 + 合并 ────────────────────────────────────────────────
mr_root = gl_root.projects.get(FULL).mergerequests.get(mr.iid)
mr_root.approve()
print("[ok] root 审批通过（POST /approve）")
# ⚠️ python-gitlab 8.6 坑：approve() 用响应替换对象 attrs，iid 变 None，
#    接着 merge() 会打到 /merge_requests/None/merge → 404。approve 后必须重取对象。
mr_root = gl_root.projects.get(FULL).mergerequests.get(mr.iid)
try:
    mr_root.merge(should_remove_source_branch=True)
except Exception as e:
    mr_root = gl_root.projects.get(FULL).mergerequests.get(mr.iid)
    print(f"[fail] merge 被拒：{e}；detailed_merge_status={mr_root.detailed_merge_status} "
          f"conflicts={mr_root.has_conflicts}")
    raise
print(f"[ok] root 合并 MR !{mr.iid}")

# ── 4. 断言：main HEAD 变更 + 审批留痕 ─────────────────────────────────
project = gl_root.projects.get(FULL)
head_after = project.commits.get("main").id
assert head_after != head_before, f"merge 后 main HEAD 未变化：{head_after}"
print(f"[ok] main HEAD 变更 {head_before[:12]} → {head_after[:12]}")
mr_root = gl_root.projects.get(FULL).mergerequests.get(mr.iid)
approvals = mr_root.approvals.get()
approved_by = [a["user"]["username"] for a in (approvals.attributes.get("approved_by") or [])]
assert approved_by, "审批记录为空（approve 未留痕）"
print(f"[ok] 审批留痕：{','.join(approved_by)}；MR 状态 {mr_root.state}")
print("[ok] 第一个 MR 评审流全链路走通")
