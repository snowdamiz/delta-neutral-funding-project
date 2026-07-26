#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
base_url=${1:-http://127.0.0.1:8080}

test "$(
  curl -sS -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' \
    --data '{}' \
    "$base_url/v1/shadow-results"
)" = "401"

SHADOW_RESULT_URL="$base_url/v1/shadow-results" \
  "$project_dir/scripts/check-shadow.sh"
curl -fsS "$base_url/v1/shadow-results" |
  jq -e '
    length >= 2 and
    any(.[]; .market == "SOL-PERP") and
    any(.[]; .market == "JUPITER:JITOSOL-USDC") and
    all(.[0:2][]; .status == "PLANNED" and .retryAllowed == true)
  ' >/dev/null

printf 'shadow persistence checks passed\n'
