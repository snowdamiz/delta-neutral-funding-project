#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
base_url=${1:-http://127.0.0.1:8080}

COLLECTOR_URL=$base_url "$project_dir/bin/collector" status |
  jq -e '.executionMode == "paper"' >/dev/null

if COLLECTOR_URL=$base_url "$project_dir/bin/collector" flatten test >/dev/null 2>&1; then
  printf 'flatten succeeded without explicit paper approval\n' >&2
  exit 1
fi

set +e
COLLECTOR_URL=http://127.0.0.1:9 \
OPERATOR_HMAC_SECRET=paper-reset-dispatch-test \
  "$project_dir/bin/collector" paper-reset \
  --initial-usdc 5000 \
  --initial-collateral 500 \
  --approve-paper-reset >/dev/null 2>&1
reset_status=$?
set -e
if [ "$reset_status" -eq 2 ]; then
  printf 'paper-reset did not reach the signed HTTP path\n' >&2
  exit 1
fi

validation_request=$(mktemp)
trap 'rm -f "$validation_request"' EXIT HUP INT TERM
printf '%s\n' '{"windowId":"dispatch-test"}' >"$validation_request"
set +e
COLLECTOR_URL=http://127.0.0.1:9 \
OPERATOR_HMAC_SECRET=validation-dispatch-test \
  "$project_dir/bin/collector" solana-validation-start "$validation_request" \
  >/dev/null 2>&1
validation_status=$?
set -e
if [ "$validation_status" -eq 2 ]; then
  printf 'solana-validation-start did not reach the signed HTTP path\n' >&2
  exit 1
fi

printf 'collector CLI checks passed\n'
