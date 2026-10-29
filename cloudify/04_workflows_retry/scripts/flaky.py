import os
import sys

from cloudify import ctx

# counter file makes the failure deterministic across retried executions:
# attempts 1..2 exit non-zero (task failure -> engine retries per max_retries),
# attempt 3 succeeds and records the number in runtime properties.
counter_file = ctx.node.properties["counter_file"]
max_attempts = 3

count = 0
if os.path.exists(counter_file):
    with open(counter_file) as f:
        count = int(f.read().strip() or "0")
count += 1
with open(counter_file, "w") as f:
    f.write(str(count))

if count < max_attempts:
    ctx.logger.info("flaky attempt {}/{} -> failing on purpose".format(count, max_attempts))
    sys.exit(1)

ctx.logger.info("flaky attempt {}/{} -> succeeding".format(count, max_attempts))
ctx.instance.runtime_properties["attempts"] = count
