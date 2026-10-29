#!/usr/bin/env bash
# runs inside the Manager's mgmtworker container
set -euo pipefail
ctx logger info "create.sh on the manager, who=${who}"
ctx instance runtime-properties said "${who}-from-cloudify-manager"
