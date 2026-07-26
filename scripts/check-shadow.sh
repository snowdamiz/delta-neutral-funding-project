#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'find "$temp_dir" -depth -delete' EXIT HUP INT TERM

run_shadow() {
  action=$1
  docker run --rm \
    --network none \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --volume "$project_dir/tests/vectors/shadow-intent-v1.json:/vectors/intent.json:ro" \
    --volume "$action:/vectors/action.json:ro" \
    --volume "$project_dir/tests/vectors/shadow-policy-v1.json:/vectors/policy.json:ro" \
    delta-neutral-funding-executor:latest \
    shadow \
    --intent /vectors/intent.json \
    --action /vectors/action.json \
    --policy /vectors/policy.json \
    --now-ms 1785024000000
}

run_shadow "$project_dir/tests/vectors/shadow-action-v1.json" |
  jq -e '
    .mode == "shadow" and
    .status == "PLANNED" and
    .authoritativeReference == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ' >/dev/null

tampered_action="$temp_dir/action.json"
jq '.programIds = ["arbitrary-program"]' \
  "$project_dir/tests/vectors/shadow-action-v1.json" >"$tampered_action"
chmod 755 "$temp_dir"
chmod 644 "$tampered_action"
if run_shadow "$tampered_action" >/dev/null 2>&1; then
  printf 'shadow executor accepted an unallowlisted program\n' >&2
  exit 1
fi

printf 'shadow executor checks passed\n'
