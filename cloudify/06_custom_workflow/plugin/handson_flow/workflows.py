from cloudify.decorators import workflow


@workflow(resumable=True)
def rolling_restart(ctx, batch, **kwargs):
    """Restart instances in batches of `batch`. Batches run back-to-back
    (dependencies), instances inside one batch run concurrently (no
    dependencies inside a subgraph)."""
    graph = ctx.graph_mode()
    # blueprint parameter constraints are NOT validated by the local engine
    # (measured: batch=-1 passes parsing), so guard here
    if batch <= 0:
        raise RuntimeError("batch must be a positive integer, got {}".format(batch))
    instances = sorted(ctx.node_instances, key=lambda inst: inst.id)
    chunks = [instances[i:i + batch] for i in range(0, len(instances), batch)]
    ctx.logger.info("rolling_restart: {} instances, batch={} -> {} batches".format(
        len(instances), batch, len(chunks)))
    previous = None
    for idx, chunk in enumerate(chunks):
        subgraph = graph.subgraph("batch-{}".format(idx))
        for instance in chunk:
            # instances without the restart operation (e.g. the finale's
            # TF/k8s substrate nodes) are skipped, not failed
            if not instance.node.has_operation(
                    "handsonflow.interfaces.lifecycle.restart"):
                continue
            # one sequence PER instance: tasks inside a sequence are serial,
            # separate sequences are dependency-free and run concurrently
            # (bounded by the executor's task thread pool size)
            sequence = subgraph.sequence()
            sequence.add(
                instance.send_event("rolling_restart: stopping to restart"),
                instance.execute_operation(
                    "handsonflow.interfaces.lifecycle.restart"),
                instance.send_event("rolling_restart: restarted"))
        if previous is not None:
            graph.add_dependency(subgraph, previous)
        previous = subgraph
    graph.execute()
