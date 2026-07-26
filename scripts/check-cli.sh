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

printf 'collector CLI checks passed\n'
