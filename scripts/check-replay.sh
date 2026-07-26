#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'find "$temp_dir" -depth -delete' EXIT HUP INT TERM

bundle="$project_dir/replay/bundles/calm-v1.jsonl"
config="$project_dir/replay/configs/baseline-v1.json"

"$project_dir/bin/collector" replay --bundle "$bundle" --config "$config" |
  jq -S -c . >"$temp_dir/first.json"
"$project_dir/bin/collector" replay --bundle "$bundle" --config "$config" |
  jq -S -c . >"$temp_dir/second.json"

cmp "$temp_dir/first.json" "$temp_dir/second.json"
jq -e '
  .mesh_commit == "105b55e1029ceba615161901c84d08a9a64885ea" and
  .event_count == 4 and
  .decision_count == 6 and
  .sol_funding_usd_micros == 92525 and
  .jitosol_funding_usd_micros == 92525 and
  .trace_hash == "4284bb84e784e9ad28c1a2baae1e7762181606b27a044a2a1e5bc32ff0b5002a"
' "$temp_dir/first.json" >/dev/null

sed 's/"seed":"42"/"seed":"43"/' "$config" >"$temp_dir/unpinned.json"
if "$project_dir/bin/collector" replay \
  --bundle "$bundle" \
  --config "$temp_dir/unpinned.json" >/dev/null 2>&1; then
  printf 'replay accepted a config that does not match the manifest hash\n' >&2
  exit 1
fi

printf 'replay checks passed\n'
