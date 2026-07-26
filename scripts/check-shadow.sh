#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'find "$temp_dir" -depth -delete' EXIT HUP INT TERM

build_action() {
  intent=$1
  simulation=$2
  output=$3
  docker run --rm \
    --network none \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --entrypoint node \
    --volume "$project_dir/tests/vectors:/vectors:ro" \
    delta-neutral-funding-adapter:latest \
    dist/shadow-cli.js \
    --intent "/vectors/$intent" \
    --simulation "/vectors/$simulation" >"$output"
}

run_shadow() {
  intent=$1
  action=$2
  docker run --rm \
    --network none \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --volume "$project_dir/tests/vectors/$intent:/vectors/intent.json:ro" \
    --volume "$action:/vectors/action.json:ro" \
    --volume "$project_dir/tests/vectors/shadow-policy-v1.json:/vectors/policy.json:ro" \
    delta-neutral-funding-executor:latest \
    shadow \
    --intent /vectors/intent.json \
    --action /vectors/action.json \
    --policy /vectors/policy.json \
    --now-ms 1785024000000
}

check_path() {
  intent=$1
  simulation=$2
  expected_market=$3
  action="$temp_dir/$intent.action.json"
  report="$temp_dir/$intent.report.json"
  build_action "$intent" "$simulation" "$action"
  run_shadow "$intent" "$action" >"$report"
  jq -s -e --arg market "$expected_market" '
    .[0].market == $market and
    .[0].simulateOnly == true and
    .[0].submit == false and
    .[1].mode == "shadow" and
    .[1].status == "PLANNED" and
    .[1].authoritativeReference == .[0].messageHash and
    .[1].simulatedQuantityAtoms == .[0].simulatedQuantityAtoms and
    .[1].simulatedAveragePriceAtoms == .[0].simulatedAveragePriceAtoms and
    .[1].simulatedFeeAtoms == .[0].simulatedFeeAtoms and
    .[1].computeUnitsConsumed == .[0].computeUnitsConsumed and
    .[1].accountDeltas == .[0].accountDeltas
  ' "$action" "$report" >/dev/null
}

chmod 755 "$temp_dir"
check_path \
  shadow-intent-v1.json \
  shadow-simulation-perp-v1.json \
  SOL-PERP
check_path \
  shadow-intent-jitosol-v1.json \
  shadow-simulation-jitosol-v1.json \
  JUPITER:JITOSOL-USDC

perp_action="$temp_dir/shadow-intent-v1.json.action.json"
jq -s -e '.[0] == .[1]' \
  "$perp_action" \
  "$project_dir/tests/vectors/shadow-action-v1.json" >/dev/null

tampered_action="$temp_dir/action.json"
jq '.programIds = ["arbitrary-program"]' \
  "$perp_action" >"$tampered_action"
chmod 644 "$tampered_action"
if run_shadow shadow-intent-v1.json "$tampered_action" >/dev/null 2>&1; then
  printf 'shadow executor accepted an unallowlisted program\n' >&2
  exit 1
fi

printf 'shadow executor checks passed\n'
