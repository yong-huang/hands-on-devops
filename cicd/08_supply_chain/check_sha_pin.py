#!/usr/bin/env python3
"""
SHA pin 检查脚本——扫描 .github/workflows/ 下所有 YAML 文件，
断言每个第三方 action（非 actions/* 官方、非本地 ./）都使用 40 位 SHA 引用。

用法：python3 check_sha_pin.py <workflows-dir>
"""
import yaml, sys, os, re

# allowlist：这些前缀被视为"可信"（GitHub 官方），可以不用 SHA pin
TRUSTED_PREFIXES = ["actions/", "github/", "gh", "."]

def is_local_or_trusted(ref):
    """判断 action 引用是否为本地或可信前缀"""
    for prefix in TRUSTED_PREFIXES:
        if ref.startswith(prefix):
            return True
    return False

def check_pin(workflows_dir):
    errors = []
    checked = 0
    for fname in sorted(os.listdir(workflows_dir)):
        if not fname.endswith((".yml", ".yaml")):
            continue
        path = os.path.join(workflows_dir, fname)
        with open(path) as f:
            docs = list(yaml.safe_load_all(f))
        for doc in docs:
            if not doc or not isinstance(doc, dict):
                continue
            jobs = doc.get("jobs", {})
            if not isinstance(jobs, dict):
                continue
            for job_name, job in jobs.items():
                if not isinstance(job, dict):
                    continue
                steps = job.get("steps", [])
                if not isinstance(steps, list):
                    continue
                for i, step in enumerate(steps):
                    if not isinstance(step, dict):
                        continue
                    uses = step.get("uses", "")
                    if not uses or is_local_or_trusted(uses):
                        continue
                    checked += 1
                    # 检查是否是 40 位 SHA（十六进制）
                    ref = uses.split("@")[-1] if "@" in uses else ""
                    if not re.fullmatch(r"[0-9a-f]{40}", ref):
                        errors.append(
                            f"  {fname}:{job_name} step {i}: {uses} → "
                            f"引用未 pin SHA（当前 ref: {ref or '无'}）"
                        )

    print(f"[scan] 检查了 {checked} 个第三方 action 引用")
    if errors:
        print(f"[fail] {len(errors)} 个引用未 pin SHA：")
        for e in errors:
            print(f"  {e}")
        sys.exit(1)
    print("[ok] 所有第三方 action 引用均为 40 位 SHA（或可信前缀豁免）")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    check_pin(sys.argv[1])
