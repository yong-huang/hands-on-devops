#!/usr/bin/env python3
"""make_pipeline.py —— 建 runner-lab 靶场项目并灌入观察用流水线（幂等）。

三条 eda job（各 sleep 6）验证 concurrent=2 的排队；一条 fpga job 验证标签路由。
"""
import sys

import gitlab

gl = gitlab.Gitlab(sys.argv[1], private_token=sys.argv[2])
design = gl.groups.get("semi/ip/design")
full = "semi/ip/design/runner-lab"
try:
    p = gl.projects.create({"path": "runner-lab", "name": "Runner 农场靶场",
                            "namespace_id": design.id, "default_branch": "main"})
    print(f"[ok] 建项目 {full}")
except gitlab.exceptions.GitlabCreateError:
    p = gl.projects.get(full)
    print(f"[  =] 项目已存在 {full}")

ci = """\
# runner-lab · 观察用流水线：标签路由 + 并发排队
default:
  image: docker.1ms.run/library/alpine:3

eda-1:
  tags: [eda]
  script: sleep 6 && echo "done on $CI_RUNNER_DESCRIPTION"
eda-2:
  tags: [eda]
  script: sleep 6 && echo "done on $CI_RUNNER_DESCRIPTION"
eda-3:
  tags: [eda]
  script: sleep 6 && echo "done on $CI_RUNNER_DESCRIPTION"
fpga-probe:
  tags: [fpga]
  script: echo "fpga job on $CI_RUNNER_DESCRIPTION"
"""
try:
    f = p.files.get(file_path=".gitlab-ci.yml", ref="main")
    if f.decode() == ci:
        print("[  =] .gitlab-ci.yml 内容一致，跳过提交")
    else:
        p.commits.create(
            {
                "branch": "main",
                "commit_message": "ci: 更新 runner 农场观察流水线",
                "actions": [{"action": "update", "file_path": ".gitlab-ci.yml", "content": ci}],
            }
        )
        print("[ok] .gitlab-ci.yml 已更新")
except gitlab.exceptions.GitlabGetError:
    p.commits.create(
        {
            "branch": "main",
            "commit_message": "ci: runner 农场观察流水线",
            "actions": [{"action": "create", "file_path": ".gitlab-ci.yml", "content": ci}],
        }
    )
    print("[ok] .gitlab-ci.yml 已提交（首次会自动触发流水线）")
