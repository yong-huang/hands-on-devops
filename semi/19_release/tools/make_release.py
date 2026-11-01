#!/usr/bin/env python3
"""make_release.py —— tag 触发的发布工程（清单项目 19）。

输入（环境变量）：RELEASE_VERSION（tag 名）、GITLAB_PAT、CI_PIPELINE_ID
产出：
  1. changelog：上一 tag → 本 tag 的 merged MR 标题列表（GitLab API）
  2. 客户交付包 dist/rtl-gcd-<ver>.tar.gz（RTL+bitstream+MANIFEST+audit.json，tar 内 sha256 自校验）
  3. GitLab Release 创建，assets 挂交付包链接
"""
import json
import os
import urllib.error
import subprocess
import sys
import tarfile
import time
import urllib.request
from pathlib import Path

# CI 容器内 localhost 不是 GitLab：runner 的 network_mode 使 job 容器与 gitlab 同网络（别名 gitlab）
IN_CI = bool(os.environ.get("CI_JOB_ID"))
URL = "http://gitlab" if IN_CI else "http://localhost:28200"
PROJECT = "semi%2Fip%2Fdesign%2Frtl-gcd"
ver = os.environ["RELEASE_VERSION"]
pat = os.environ["GITLAB_PAT"]


def api(path):
    r = urllib.request.Request(f"{URL}/api/v4/{path}",
                               headers={"PRIVATE-TOKEN": pat})
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read())


def api_post(path, body):
    r = urllib.request.Request(f"{URL}/api/v4/{path}",
                               data=json.dumps(body).encode(),
                               headers={"PRIVATE-TOKEN": pat,
                                        "Content-Type": "application/json"},
                               method="POST")
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"[release] POST {path} -> {e.code}: {e.read().decode(errors='replace')[:300]}",
              file=sys.stderr)
        raise


project = api(f"projects/{PROJECT}")
pid = project["id"]

# ── 1. changelog：上一 tag 起的 merged MR ──
tags = api(f"projects/{pid}/repository/tags")
prev = tags[1]["name"] if len(tags) > 1 else None
mrs = api(f"projects/{pid}/merge_requests?state=merged&target_branch=main"
          f"&order_by=updated_at&per_page=50")
lines = [f"- !{m['iid']} {m['title']} (@" + m['author']['username'] + ")" for m in mrs]
changelog = (f"# rtl-gcd {ver}\n\n"
             f"自 {prev or '仓库起点'} 以来的变更（merged MR）：\n" + "\n".join(lines))
Path("CHANGELOG.md").write_text(changelog)
print(f"[release] changelog：{len(lines)} 条 MR（自 {prev or '起点'}）")

# ── 2. 客户交付包 ──
dist = Path("dist")
dist.mkdir(exist_ok=True)
audit = {
    "version": ver,
    "built_at": time.strftime("%FT%T%z"),
    "pipeline": os.environ.get("CI_PIPELINE_ID", "local"),
    "packaged_by": "make_release.py",
    "contents": ["rtl/", "syn/top.bin", "MANIFEST.sha256", "CHANGELOG.md"],
}
Path("audit.json").write_text(json.dumps(audit, ensure_ascii=False, indent=1))

# MANIFEST：对包内关键文件做 sha256（消费端解包后逐条对账）
import hashlib
manifest_lines = []
for f in ["syn/top.bin", "CHANGELOG.md", "audit.json"]:
    digest = hashlib.sha256(Path(f).read_bytes()).hexdigest()
    manifest_lines.append(f"{digest}  {f}")
Path("MANIFEST.sha256").write_text("\n".join(manifest_lines) + "\n")

pkg = dist / f"rtl-gcd-{ver}.tar.gz"
with tarfile.open(pkg, "w:gz") as t:
    t.add("rtl", arcname="rtl")
    t.add("syn/top.bin", arcname="syn/top.bin")
    t.add("MANIFEST.sha256", arcname="MANIFEST.sha256")
    t.add("CHANGELOG.md", arcname="CHANGELOG.md")
    t.add("audit.json", arcname="audit.json")
print(f"[release] 交付包 {pkg}（{pkg.stat().st_size // 1024}KB）")

# ── 3. GitLab Release（说明=changelog，assets=交付包上传链接）──
# /uploads 要 multipart 文件体（JSON 会报 file is missing）；容器内无 curl → 手工 multipart
from urllib.request import Request
boundary = "----gcdboundary7d1a2c"
body = (
    f"--{boundary}\r\n"
    f'Content-Disposition: form-data; name="file"; filename="{pkg.name}"\r\n'
    "Content-Type: application/gzip\r\n\r\n"
).encode() + pkg.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
r = Request(f"{URL}/api/v4/projects/{pid}/uploads", data=body, method="POST")
r.add_header("PRIVATE-TOKEN", pat)
r.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
with urllib.request.urlopen(r, timeout=120) as resp:
    upload = json.loads(resp.read())
asset_path = upload["url"]   # /uploads/<hash>/<file>
api_post(f"projects/{pid}/releases", {
    "tag_name": ver,
    "description": changelog,
    "assets": {"links": [
        {"name": "客户交付包 (tar.gz)", "url": f"{URL}/api/v4/projects/{pid}/packages/generic/rtl-gcd-release/{ver}/{pkg.name}"},
        {"name": "交付审计单 (audit.json)", "url": f"{URL}/-/jobs/{os.environ.get('CI_JOB_ID','0')}/artifacts/audit.json"},
    ]},
})
# 交付包同时入 Generic Packages（Release 链接可直接下载）
r = Request(f"{URL}/api/v4/projects/{pid}/packages/generic/rtl-gcd-release/{ver}/{pkg.name}",
            data=pkg.read_bytes(), method="PUT")
r.add_header("PRIVATE-TOKEN", pat)
with urllib.request.urlopen(r, timeout=300) as resp:
    code = resp.status
print(f"[release] Release {ver} 已创建；交付包入 Generic Packages（HTTP {code}）")
print("[release] done")
