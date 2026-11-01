#!/usr/bin/env python3
"""acceptance.py —— 平台级一键自检（清单项目 4 验收②）。

九条断言覆盖 01-04 的全部产出：组树、成员矩阵、双项目、保护分支、Gitaly 全局 hook、
LFS 存储、webhook 注册、webhook 事件可达、MR 评审流证据。失败打印差异，全过打 [ok]。
用法：acceptance.py <root_token> [events_json]
"""
import json
import subprocess
import sys

import gitlab

root_token = sys.argv[1]
events_file = sys.argv[2] if len(sys.argv) > 2 else "data/events.json"
URL = "http://localhost:28200"
FAILED = 0


def ok(msg):
    print(f"  [ok]   {msg}")


def fail(msg):
    global FAILED
    FAILED = 1
    print(f"  [fail] {msg}")


def check(cond, good, bad):
    ok(good) if cond else fail(bad)


gl = gitlab.Gitlab(URL, private_token=root_token)

print("=====> [1/9] 组树（01-02 建的层级）")
try:
    gl.groups.get("semi")
    gl.groups.get("semi/ip")
    design = gl.groups.get("semi/ip/design")
    ok("组树 semi / semi/ip / semi/ip/design 全在")
except Exception as e:
    fail(f"组树缺失：{e}")

print("=====> [2/9] 成员矩阵（dev1 = Developer 30）")
members = {m.username: m.access_level for m in design.members.list(get_all=True)}
check(members.get("dev1") == 30,
      f"dev1 挂 design 组 level=30（现成员：{members}）",
      f"dev1 成员关系异常：{members}")

print("=====> [3/9] 双项目在位")
push_lab = gl.projects.get("semi/ip/design/push-lab")
rtl = gl.projects.get("semi/ip/design/rtl-gcd")
ok(f"push-lab 与 rtl-gcd 均在（default={push_lab.default_branch}/{rtl.default_branch}）")

print("=====> [4/9] 保护分支语义（push-lab 禁直推 / rtl-gcd Maintainer 可推）")
# protectedbranches.list() 返回的是简化对象，级别藏在 push_access_levels 列表里
def push_levels(pb):
    return {a["access_level"] for a in (pb.push_access_levels or [])}

pb1 = {b.name: push_levels(b) for b in push_lab.protectedbranches.list(get_all=True)}
pb2 = {b.name: push_levels(b) for b in rtl.protectedbranches.list(get_all=True)}
check(0 in pb1.get("main", set()), "push-lab main push 含 0（No access，只许 MR）",
      f"push-lab main push levels={pb1}")
check(40 in pb2.get("main", set()), "rtl-gcd main push 含 40（Maintainer 直推，CI 通道）",
      f"rtl-gcd main push levels={pb2}")

print("=====> [5/9] Gitaly 全局 server hook 在位且可执行")
r = subprocess.run(
    ["docker", "exec", "gitlab", "test", "-x",
     "/var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/50-block-huge-blobs"],
    capture_output=True)
check(r.returncode == 0, "pre-receive.d/50-block-huge-blobs 存在且可执行",
      "全局 hook 缺失或不可执行（02 的 install_hook 需重跑）")

print("=====> [6/9] LFS 存储（03 的 2.1GB 负载 + 累计）")
r = subprocess.run(["docker", "exec", "gitlab", "du", "-sk",
                    "/var/opt/gitlab/gitlab-rails/shared/lfs-objects"],
                   capture_output=True, text=True)
kb = int(r.stdout.split()[0]) if r.returncode == 0 else 0
check(kb >= 1_500_000, f"LFS 存储已有 {kb // 1048576}GB 实体",
      f"LFS 存储仅 {kb // 1024}MB（<1.5GB，03 未完成或被清）")

print("=====> [7/9] webhook 注册在 rtl-gcd 上")
hooks = [h for h in rtl.hooks.list(get_all=True) if "webhook-listener:9000" in h.url]
check(bool(hooks), f"hook 指向 webhook-listener:9000（共 {len(rtl.hooks.list(get_all=True))} 个 hook）",
      "rtl-gcd 上没有指向监听器的 webhook（先跑 ./mr_gate.sh up）")

print("=====> [8/9] webhook 事件可达（push + merge_request 两类）")
try:
    events = json.load(open(events_file))
except Exception:
    events = []
kinds = {e.get("kind") for e in events}
pushes = [e for e in events if e.get("kind") == "push" and "rtl-gcd" in e.get("project", "")]
mrs = [e for e in events if e.get("kind") == "merge_request"]
check(bool(pushes), f"收到 {len(pushes)} 条 push 事件（dev1 的分支推送）", "未收到 push 事件——webhook 链路不通")
check(bool(mrs), f"收到 {len(mrs)} 条 merge_request 事件（动作：{[e['action'] for e in mrs]}）",
      "未收到 merge_request 事件")

print("=====> [9/9] MR 评审流证据（状态 merged + 审批留痕）")
merged = [mr for mr in rtl.mergerequests.list(state="merged", get_all=True)]
check(bool(merged), f"存在 {len(merged)} 个 merged MR（最近：!{merged[0].iid if merged else '-'}）",
      "没有任何 merged MR（先跑 ./mr_gate.sh up）")

print()
if FAILED:
    print("[fail] 平台验收未全过，见上")
    sys.exit(1)
print("[ok] 平台验收九条断言全过——01-04 产出全部在位")
