#!/usr/bin/env bash
# op-input get_attribute runs at TASK time, so $net carries the TF output
set -euo pipefail
ctx logger info "recorded network from TF output: ${net}"
ctx instance runtime-properties recorded_network "${net}"
