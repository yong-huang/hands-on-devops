#!/usr/bin/env bash
# TF wrapper (create + maintenance.apply): stage module, init (provider from
# the filesystem mirror staged by the main script), apply, publish outputs.
set -euo pipefail
BIN="$tf_binary"
ZIP="$tf_zip"
WORK="$workdir"

if [ -f "$WORK/terraform.tfstate" ]; then
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
"$BIN" apply -auto-approve -input=false >/dev/null

NETWORK=$("$BIN" output -json network_name | tr -d '"')
ctx instance runtime-properties tf_network "$NETWORK"
ctx instance runtime-properties tf_workdir "$WORK"
ctx logger info "tf apply done: network=$NETWORK"
