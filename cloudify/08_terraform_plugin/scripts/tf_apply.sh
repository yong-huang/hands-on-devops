#!/usr/bin/env bash
# apply (create hook & maintenance.apply): stage module zip -> init -> apply.
# Incremental: terraform reconcile the state, so replicas 1->2 only adds.
set -euo pipefail
BIN="$tf_binary"
ZIP="$tf_zip"
WORK="$workdir"
REPLICAS="${replicas:-1}"

if [ -f "$WORK/terraform.tfstate" ]; then
    # reload path: keep the existing state so terraform reconciles incrementally
    ctx logger info "reusing existing workdir with state: $WORK"
    cd "$WORK"
else
    mkdir -p "$WORK"
    rm -rf "$WORK"
    mkdir -p "$WORK"
    unzip -o -q "$ZIP" -d "$WORK"
    cd "$WORK"
fi
export TF_IN_AUTOMATION=1
if [ -n "${tf_cli_config:-}" ]; then
    export TF_CLI_CONFIG_FILE="$tf_cli_config"
fi

if [ ! -d .terraform/providers ]; then
    "$BIN" init -input=false >/dev/null
fi
"$BIN" apply -auto-approve -input=false -var "replicas=$REPLICAS" >/dev/null

NAMES=$("$BIN" output -json names)
ctx instance runtime-properties tf_names "$NAMES"
ctx instance runtime-properties tf_workdir "$WORK"
ctx instance runtime-properties tf_replicas "$REPLICAS"
ctx logger info "tf apply done: replicas=$REPLICAS names=$NAMES"
