#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
echo "== bad-deployment (预期：deny latest + no resources):"
conftest test fixtures/bad-deployment.json -p policies/ 2>&1 | sed 's/^/  /' || true
echo "== good-deployment (预期：pass):"
conftest test fixtures/good-deployment.json -p policies/ 2>&1 | sed 's/^/  /'
