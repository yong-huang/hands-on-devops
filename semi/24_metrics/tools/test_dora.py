#!/usr/bin/env python3
"""test_dora.py —— 已知数据集单测（3 红 7 绿 + MTTR 校准）。

用假 GitLab 响应（monkeypatch collect 的数据源）验证计算逻辑：
  成功率 70%、CFR 30%、MTTR 与手工推算一致（±1min）。
"""
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import dora_report


class FakePipeline:
    def __init__(self, status, created_at, duration=300):
        self.status = status
        self.created_at = created_at
        self.duration = duration


def make_pipelines():
    """10 条流水线：3 红 7 绿，红在 t+10min 有绿。"""
    t0 = datetime.now(timezone.utc) - timedelta(days=5)
    out = []
    states = ["success"] * 7
    for i, s in enumerate(states[:3]):
        pass
    # 明确构造：positions 2,5,8 为 failed，其后紧接 success
    pattern = ["success", "success", "failed", "success", "success",
               "failed", "success", "success", "failed", "success"]
    for i, s in enumerate(pattern):
        out.append(FakePipeline(s, (t0 + timedelta(hours=i)).isoformat()))
    return out


class TestDoraMath(unittest.TestCase):
    def setUp(self):
        self.pls = make_pipelines()

    def test_counts_and_mttr(self):
        r = dora_report.compute_from_pipelines(self.pls, releases=[], days=30)
        self.assertEqual(r["pipelines_total"], 10)
        self.assertEqual(r["pipelines_failed"], 3)
        self.assertEqual(r["change_failure_rate_pct"], 30.0)
        self.assertEqual(r["success_rate_pct"], 70.0)
        # 每个失败后 1h 紧跟 success → MTTR = 60min ×3 取平均
        self.assertEqual(r["mttr_minutes"], 60.0)


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


if __name__ == "__main__":
    unittest.main()
