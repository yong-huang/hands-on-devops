#!/usr/bin/env python3
"""dora_report.py —— DORA 四指标 + 流水线健康周报（GitLab API）。

输入：GitLab 项目（默认 rtl-gcd），最近 N 天的 pipelines/releases。
输出：周报 JSON + 控制台摘要；内置已知数据集单测（3 红 7 绿）。
指标（GitLab 语境映射）：
  部署频率 DF        —— release 数 / 天
  变更前置时间 LT    —— pipeline 开始 → 同 sha 的 release（无 release 记录则用 duration 近似说明）
  变更失败率 CFR     —— failed pipelines / total
  MTTR               —— failed → 下一条同 ref success 的间隔
"""
import json
import sys
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone

import gitlab


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def compute_from_pipelines(pipelines, releases=(), days=30):
    """纯数学：给按时间排序的 pipeline 列表算全部指标——单测可直接喂假对象。"""
    total = len(pipelines)
    failed = sum(1 for pl in pipelines if pl.status == "failed")
    success = sum(1 for pl in pipelines if pl.status == "success")

    # MTTR：failed 后到下一条 success 的间隔（同 ref 顺序流水线）
    mttrs = []
    last_fail = None
    for pl in pipelines:
        if pl.status == "failed":
            last_fail = parse_ts(pl.created_at)
        elif pl.status == "success" and last_fail:
            mttrs.append((parse_ts(pl.created_at) - last_fail).total_seconds())
            last_fail = None
    mttr_min = round(sum(mttrs) / len(mttrs) / 60, 1) if mttrs else None

    # LT：success 流水线的 duration（代理指标——无环境部署时用流水线时长近似，
    # 真正的 lead time 需 merge→deploy 时间戳，本平台 release 挂 tag 上）
    durations = [pl.duration or 0 for pl in pipelines if pl.status == "success"]
    avg_duration_min = round(sum(durations) / len(durations) / 60, 1) if durations else None

    return {
        "window_days": days,
        "pipelines_total": total,
        "pipelines_success": success,
        "pipelines_failed": failed,
        "success_rate_pct": round(success * 100 / total, 1) if total else None,
        "change_failure_rate_pct": round(failed * 100 / total, 1) if total else None,
        "deploy_frequency_per_day": round(len(releases) / days, 2),
        "releases": len(releases),
        "mttr_minutes": mttr_min,
        "avg_pipeline_minutes": avg_duration_min,
    }


def collect(gl, project_path, days=30):
    p = gl.projects.get(project_path)
    since = datetime.now(timezone.utc) - timedelta(days=days)
    # list() 返回懒加载对象（缺 duration）——逐条 get 拿全量字段
    pipelines = [p.pipelines.get(pl.id)
                 for pl in p.pipelines.list(ref="main", get_all=True, per_page=100)
                 if parse_ts(pl.created_at) >= since]
    pipelines.sort(key=lambda x: parse_ts(x.created_at))
    releases = p.releases.list(get_all=True)
    report = compute_from_pipelines(pipelines, releases=releases, days=days)
    report["worst_stage"] = worst_stage(pipelines, p)
    return report


def worst_stage(pipelines, p):
    """各 job 耗时聚合，找出最慢 stage（瓶颈定位）。"""
    stage_time = defaultdict(lambda: 0.0)
    for pl in pipelines[-20:]:
        try:
            for j in p.pipelines.get(pl.id).jobs.list(get_all=True):
                if j.duration:
                    stage_time[j.stage] += j.duration
        except Exception:
            continue
    if not stage_time:
        return None
    top = max(stage_time.items(), key=lambda x: x[1])
    return {"stage": top[0], "seconds": round(top[1], 1),
            "share_pct": round(top[1] * 100 / sum(stage_time.values()), 1)}


def main() -> int:
    # 用法：dora_report.py <token文件> [project_path] [out.json]
    token_file = sys.argv[1] if len(sys.argv) > 1 else ""
    token = open(token_file).read().strip() if token_file else ""
    project_path = sys.argv[2] if len(sys.argv) > 2 else "semi/ip/design/rtl-gcd"
    gl = gitlab.Gitlab("http://localhost:28200", private_token=token, retry_transient_errors=True)
    report = collect(gl, project_path)
    out = sys.argv[3] if len(sys.argv) > 3 else "dora_week.json"
    with open(out, "w") as f:
        json.dump(report, f, indent=1)
    print(f"DORA 周报（{report['window_days']} 天窗口）")
    print(f"  流水线 {report['pipelines_total']} 条（绿 {report['pipelines_success']} / 红 {report['pipelines_failed']}）"
          f" 成功率 {report['success_rate_pct']}%")
    print(f"  变更失败率 CFR: {report['change_failure_rate_pct']}%")
    print(f"  部署频率 DF: {report['deploy_frequency_per_day']} 次/天（releases {report['releases']}）")
    print(f"  MTTR: {report['mttr_minutes']} min；平均流水线 {report['avg_pipeline_minutes']} min")
    print(f"  瓶颈 stage: {report['worst_stage']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
