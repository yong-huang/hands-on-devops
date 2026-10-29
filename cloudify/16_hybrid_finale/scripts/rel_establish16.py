# establish on the web container: run ansible against it (community.docker
# connection) to drop the finale marker file, then record the cross-tool data
# flow (TF network name -> web container) in runtime properties.
import re
import subprocess

from cloudify import ctx
from cloudify.exceptions import NonRecoverableError

stage = ctx.source.node.properties["stage_dir"]
container_id = ctx.target.instance.runtime_properties.get("container")
tf_network = ctx.source.node.properties.get("tf_network_hint") or ""
if not container_id:
    raise NonRecoverableError("target has no 'container' runtime property")

inventory = "{}/inventory.yaml".format(stage)
with open(inventory, "w") as f:
    f.write("""all:
  hosts:
    cfy16-web:
      ansible_connection: community.docker.docker
      ansible_host: {cid}
      ansible_python_interpreter: /usr/local/bin/python3
""".format(cid=container_id))

proc = subprocess.run(
    ["ansible-playbook", "-i", inventory, "{}/site.yaml".format(stage)],
    capture_output=True, text=True, timeout=600)
for line in proc.stdout.splitlines():
    if "changed=" in line:
        ctx.logger.info("recap: {}".format(line.strip()))
if proc.returncode != 0:
    ctx.logger.info("ansible stderr tail: {}".format(proc.stderr[-400:]))
    raise NonRecoverableError("ansible-playbook failed rc={}".format(proc.returncode))

ctx.source.instance.runtime_properties["configured_file"] = "/etc/motd"
ctx.source.instance.runtime_properties["on_network"] = tf_network
ctx.logger.info("web configured by ansible; network hint={}".format(tf_network))
