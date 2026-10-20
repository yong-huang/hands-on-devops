#!/usr/bin/env python3
"""DORA 四指标提取：全部来自 gh api（deployments + pull requests）。

用法: metrics.py <owner> <repo>
输出 JSON：部署频率 / 变更前置时长 / 变更失败率 / MTTR。
"""
import json
import subprocess
import sys
from datetime import datetime, timezone

owner, repo = sys.argv[1], sys.argv[2]


def gh(path):
    out = subprocess.run(
        ["gh", "api", f"repos/{owner}/{repo}/{path}"],
        capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"gh api {path}: {out.stderr[:200]}")
    return json.loads(out.stdout)


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


deployments = gh("deployments?environment=production&per_page=30")
prod = []
for d in deployments:
    statuses = gh(f"deployments/{d['id']}/statuses")
    # 只统计我们主动创建并写了描述的记录（environment job 会为每次 run
    # 自动生成无描述的 deployment 行——那是平台噪音，不是发布事件）
    ours = [st for st in statuses if (st.get("description") or "").strip()]
    if not ours:
        continue
    latest = ours[0]
    prod.append({
        "id": d["id"], "sha": d["sha"][:7],
        "created_at": d["created_at"],
        "state": latest.get("state"),
        "status_at": latest.get("created_at"),
        "description": latest.get("description", ""),
    })

successes = [p for p in prod if p["state"] == "success"]
failures = [p for p in prod if p["state"] == "failure"]

# 变更前置时长：最新合并 PR 的 merged_at → 其后首次 prod 成功部署
# （交付语义：合并之后第一次把变更带上生产的时刻）
lead = None
if successes:
    pulls = gh("pulls?state=closed&per_page=30&sort=updated&direction=desc")
    for pr in pulls:
        if not pr["merged_at"]:
            continue
        merged = ts(pr["merged_at"])
        after = sorted((p for p in successes if ts(p["status_at"]) >= merged),
                       key=lambda p: p["status_at"])
        if after:
            first = after[0]
            lead = {"pr": pr["number"], "sha": first["sha"],
                    "merged_at": pr["merged_at"],
                    "deployed_at": first["status_at"],
                    "seconds": round((ts(first["status_at"]) - merged).total_seconds())}
            break

# MTTR：事件流语义——所有部署的 status 按时序排列，
# 最近一次 failure 事件之后的首个 success 事件即为恢复
# （含同一 deployment 内 failure→success 的自愈；墙钟差含人工等待窗口）
# 事件流收集：主动写入的 status（带描述）都算事件——包括被后续
# 状态覆盖的中间态（如 drill 的 failure 被恢复 success 覆盖）
events = []
for d in deployments:
    for st in gh(f"deployments/{d['id']}/statuses"):
        if (st.get("description") or "").strip() and st.get("state") in ("failure", "success"):
            events.append((ts(st["created_at"]), st["state"]))
events.sort()
mttr_seconds = None
mttr = None
last_fail = None
for at, kind in events:
    if kind == "failure":
        last_fail = at
    elif kind == "success" and last_fail is not None:
        mttr_seconds = round((at - last_fail).total_seconds())
        mttr = {"failure_at": last_fail.isoformat(),
                "restored_at": at.isoformat(),
                "seconds": mttr_seconds,
                "note": "墙钟差，含人工介入等待窗口"}
        last_fail = None

total = len(prod)
result = {
    "repo": f"{owner}/{repo}",
    "environment": "production",
    "deployment_frequency": {
        "prod_deployments_total": total,
        "success": len(successes),
        "failed": len(failures),
    },
    "lead_time_for_changes": lead or {"seconds": None},
    "change_failure_rate": {
        "deployments": total, "failed": len(failures),
        "rate": round(len(failures) / total, 4) if total else None,
    },
    "mttr_seconds": mttr_seconds,
    "mttr": mttr,
    "deployments": prod,
}
print(json.dumps(result, ensure_ascii=False, indent=2))
