#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
max_gap_ms=${SOAK_MAX_GAP_MS:-60000}

case "$max_gap_ms" in
  '' | *[!0-9]* | 0)
    printf 'SOAK_MAX_GAP_MS must be a positive integer\n' >&2
    exit 1
    ;;
esac

now_ms=$(( $(date +%s) * 1000 ))
docker compose --project-directory "$project_dir" exec -T postgres \
  psql -U funding -d funding -Atc \
  "SELECT paper_soak_evidence($now_ms, $max_gap_ms)" |
  jq .
