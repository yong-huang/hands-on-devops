#!/usr/bin/env bash
# drift_check: terraform plan -detailed-exitcode (0=no drift, 2=drift),
# then converge with apply so the deployment returns to the declared state.
# NOTE: the replicas variable MUST be passed on every plan/apply - otherwise
# terraform falls back to the module default and "converging" would DELETE
# the extra replicas (measured: web-1 was destroyed that way).
set -euo pipefail
BIN="$tf_binary"
WORK="$workdir"
REPLICAS="${replicas:-1}"
cd "$WORK"
export TF_IN_AUTOMATION=1
if [ -n "${tf_cli_config:-}" ]; then
    export TF_CLI_CONFIG_FILE="$tf_cli_config"
fi

set +e
"$BIN" plan -detailed-exitcode -input=false -var "replicas=$REPLICAS" >/dev/null 2>&1
CODE=$?
set -e

if [ "$CODE" = "2" ]; then
    ctx instance runtime-properties drift_detected "yes"
    ctx logger info "drift detected (plan exit 2) -> converging"
    "$BIN" apply -auto-approve -input=false -var "replicas=$REPLICAS" >/dev/null
    ctx instance runtime-properties converged "yes"
else
    ctx instance runtime-properties drift_detected "no"
    ctx logger info "no drift (plan exit $CODE)"
fi
