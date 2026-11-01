#!/usr/bin/env python3
"""render_dashboard.py —— 读历次 sim/summary.json 渲染纯静态 HTML+SVG 趋势站（无 JS 框架）。

输入：history/ 下按时间戳命名的 summary 快照（collect_history.py 生成）+ 最新 summary.json。
输出：dashboard/index.html（内联 SVG：通过率趋势 + 失败种子分布）。
"""
import glob
import json
import os
from datetime import datetime
from pathlib import Path

HIST_DIR = Path("history")
OUT = Path("dashboard")


def load_history():
    snaps = []
    for f in sorted(glob.glob(str(HIST_DIR / "snap_*.json"))):
        d = json.load(open(f))
        d["_ts"] = os.path.basename(f)[5:-5]
        snaps.append(d)
    return snaps


def svg_polyline(snaps, key, w, h, pad, max_v, color):
    """通用折线：key 取值归一化到 (h-2*pad)。"""
    n = len(snaps)
    if n < 2:
        return ""
    pts = []
    for i, s in enumerate(snaps):
        x = pad + i * (w - 2 * pad) / (n - 1)
        v = s.get(key, 0)
        y = h - pad - (v / max_v) * (h - 2 * pad)
        pts.append(f"{x:.1f},{y:.1f}")
    return (f'<polyline fill="none" stroke="{color}" stroke-width="2" '
            f'points="{" ".join(pts)}"/>')


def main() -> int:
    snaps = load_history()
    latest = json.load(open("summary.json")) if os.path.exists("summary.json") else {}
    if snaps:
        latest = snaps[-1]
    OUT.mkdir(exist_ok=True)

    W, H, PAD = 640, 220, 30
    passed_svg = svg_polyline(snaps, "passed", W, H, PAD, 16, "#2e7d32")
    failed_svg = svg_polyline(snaps, "failed", W, H, PAD, 16, "#c62828")

    rows = "".join(
        f"<tr><td>{s['_ts']}</td><td>{s.get('passed','-')}/16</td>"
        f"<td>{','.join(s.get('failed_seeds', [])) or '-'}</td>"
        f"<td>{s.get('verdict','-')}</td></tr>"
        for s in reversed(snaps)
    )
    html = f"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<title>rtl-gcd 回归仪表盘</title>
<style>body{{font-family:sans-serif;margin:24px}} table{{border-collapse:collapse}}
td,th{{border:1px solid #ccc;padding:4px 10px;font-size:14px}}</style></head>
<body>
<h1>rtl-gcd 回归仪表盘</h1>
<p>快照数 {len(snaps)} ｜ 最新 verdict：<b>{latest.get('verdict','-')}</b>（passed {latest.get('passed','-')}/16）</p>
<h2>通过/失败趋势（passed 绿 / failed 红）</h2>
<svg width="{W}" height="{H}" xmlns="http://www.w3.org/2000/svg">
  <rect width="{W}" height="{H}" fill="#fafafa"/>
  {passed_svg}{failed_svg}
</svg>
<h2>失败种子分布（最新）</h2>
<p>{', '.join(latest.get('failed_seeds', []) or ['无'])}</p>
<h2>历史快照</h2>
<table><tr><th>时间戳</th><th>passed/16</th><th>failed_seeds</th><th>verdict</th></tr>{rows}</table>
</body></html>"""
    (OUT / "index.html").write_text(html)
    print(f"dashboard: {len(snaps)} snapshots -> {OUT}/index.html")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
