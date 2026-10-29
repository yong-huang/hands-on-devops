#!/usr/bin/env python3
"""Query Cloudify local-mode file storage.

The local CLI hides `node-instances` / `nodes` / `events` (manager-only or
broken locally), but state lives in plain JSON under the workdir:
  <workdir>/.cloudify/profiles/local/deployments/<deployment>/node-instances/*.json

Usage:
  local_query.py <workdir> <deployment_id> [--alive] [--json] [--attr KEY]

  --alive    only records whose state != "deleted"
  --json     dump full instance records
  --attr KEY print runtime_properties[KEY] per instance (empty line if absent)
"""
import json
import pathlib
import sys


def main() -> None:
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    workdir, deployment = args[0], args[1]
    alive_only = "--alive" in args
    dump_json = "--json" in args
    attr = args[args.index("--attr") + 1] if "--attr" in args else None

    base = (pathlib.Path(workdir) / ".cloudify/profiles/local/deployments"
            / deployment / "node-instances")
    records = []
    for path in sorted(base.glob("*.json")):
        record = json.loads(path.read_text())
        if alive_only and record.get("state") == "deleted":
            continue
        records.append(record)

    if dump_json:
        print(json.dumps(records, indent=2))
    elif attr is not None:
        for record in records:
            print(record.get("runtime_properties", {}).get(attr, ""))
    else:
        for record in records:
            print(record["id"], record["state"])


if __name__ == "__main__":
    main()
