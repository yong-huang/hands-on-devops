#!/usr/bin/env bash
# delete hook: destroy the TF-managed substrate
set -euo pipefail
BIN="$tf_binary"
WORK="$workdir"
cd "$WORK"
export TF_IN_AUTOMATION=1
if [ -n "${tf_cli_config:-}" ]; then
    export TF_CLI_CONFIG_FILE="$tf_cli_config"
fi
"$BIN" destroy -auto-approve -input=false >/dev/null
ctx logger info "tf destroy done: workdir=$WORK"
