# establish (relationship context) AND maintenance.reconfigure (node context
# via execute_operation): both run the same configuration. The container id
# comes from the target's runtime properties on first configure, and from the
# instance's own record on re-runs (a node context has no ctx.target, and
# ctx.node/ctx.instance are context-type sensitive - measured).
import re
import subprocess

from cloudify import ctx
from cloudify.exceptions import NonRecoverableError


def _context_views():
    """Return (props, stage_dir, container_id) for both context types."""
    try:
        # relationship context: source side carries props, target the container
        props = ctx.source.instance.runtime_properties
        stage = ctx.source.node.properties["stage_dir"]
        container_id = ctx.target.instance.runtime_properties.get("container")
        return props, stage, container_id
    except Exception:
        # node context (execute_operation re-run)
        props = ctx.instance.runtime_properties
        stage = ctx.node.properties["stage_dir"]
        return props, stage, props.get("target_container")


props, stage, container_id = _context_views()
if not container_id:
    raise NonRecoverableError(
        "no container id available (target props missing and nothing recorded "
        "from a previous configure run)")

inventory = "{}/inventory.yaml".format(stage)
with open(inventory, "w") as f:
    f.write("""all:
  hosts:
    cfy09-target:
      ansible_connection: community.docker.docker
      ansible_host: {cid}
""".format(cid=container_id))

ctx.logger.info("ansible inventory written to {} (container {})".format(
    inventory, container_id[:12]))

proc = subprocess.run(
    ["ansible-playbook", "-i", inventory, "{}/site.yaml".format(stage)],
    capture_output=True, text=True, timeout=600)
ctx.logger.info("ansible-playbook rc={}".format(proc.returncode))
for line in proc.stdout.splitlines():
    if "PLAY RECAP" in line or "changed=" in line:
        ctx.logger.info("recap: {}".format(line.strip()))
if proc.returncode != 0:
    ctx.logger.info("ansible stderr tail: {}".format(proc.stderr[-500:]))
    raise NonRecoverableError("ansible-playbook failed rc={}".format(
        proc.returncode))

recap = re.findall(r"changed=(\d+)", proc.stdout)
changed_count = sum(int(n) for n in recap)
runs = props.get("configure_runs", 0) + 1
props["configure_runs"] = runs
props["ansible_changed"] = "yes" if changed_count else "no"
props["ansible_changed_tasks"] = changed_count
props["configured_file"] = "/etc/motd"
props["target_container"] = container_id[:12]
ctx.logger.info("configure run #{}: changed_tasks={}".format(runs, changed_count))
