#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
output=$(mktemp)
trap 'rm -f "$output"' EXIT HUP INT TERM

"$project_dir/dev.sh" help | grep -Fq \
  'reset-db --approve-paper-reset'

if "$project_dir/dev.sh" reset-db >"$output" 2>&1; then
  printf 'reset-db accepted a request without explicit approval\n' >&2
  exit 1
fi
grep -Fq 'reset-db requires --approve-paper-reset' "$output"

if "$project_dir/dev.sh" reset-db --approve-paper-reset unexpected \
  >"$output" 2>&1; then
  printf 'reset-db accepted unexpected arguments\n' >&2
  exit 1
fi
grep -Fq 'reset-db requires --approve-paper-reset' "$output"

printf 'dev command checks passed\n'
