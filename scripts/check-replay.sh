#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'find "$temp_dir" -depth -delete' EXIT HUP INT TERM

config="$project_dir/replay/configs/baseline-v1.json"

for scenario in calm volatile liquidity-loss doubled-costs epoch-boundary failure; do
  bundle="$project_dir/replay/bundles/$scenario-v1.jsonl"
  first="$temp_dir/$scenario-first.json"
  second="$temp_dir/$scenario-second.json"
  "$project_dir/bin/collector" replay --bundle "$bundle" --config "$config" |
    jq -S -c . >"$first"
  "$project_dir/bin/collector" replay --bundle "$bundle" --config "$config" |
    jq -S -c . >"$second"
  cmp "$first" "$second"
  jq -e --arg scenario "$scenario-v1" '
    .bundle_id == $scenario and
    .mesh_commit == "c5379f8d00990df18248e4bf2d53bbb1d04868fb"
  ' "$first" >/dev/null
  case "$scenario" in
    calm)
      jq -e '
        .sol_funding_usd_micros == 92525 and
        .jitosol_funding_usd_micros == 92525 and
        .trace_hash == "776326623977543dd62d3f845b78fbbdfa9c1e27b81676899153611de0805aee"
      ' "$first" >/dev/null
      ;;
    volatile)
      jq -e '
        .jitosol_rebalances == 1 and
        .jitosol_basis_lamports == -334000000 and
        .trace_hash == "0d7702e8459a9f1ea15e960e1b02a1381401734f6ff0f54f531bc1b8ebde4bef"
      ' "$first" >/dev/null
      ;;
    liquidity-loss)
      jq -e '
        .sol_emergencies == 0 and
        .jitosol_emergencies == 1 and
        .trace_hash == "3f4dea289929a339ed544d2a145acffa65e768b21c0cab910bd375946c1d6a0b"
      ' "$first" >/dev/null
      ;;
    doubled-costs)
      jq -e '
        .sol_execution_fees_usd_micros == 1332362 and
        .jitosol_execution_fees_usd_micros == 1332762 and
        .trace_hash == "1c98a9c25c0d981e88e8fd05558641f9d5eaf2e2596847757b506f4ffe9f73d9"
      ' "$first" >/dev/null
      ;;
    epoch-boundary)
      jq -e '
        .jitosol_reward_lamports == 2000000 and
        .jitosol_basis_lamports == -2000000 and
        .trace_hash == "5638bfeafb8c50517fc1f2fc0b09576ef139e1ad9fdfa389ae80c7f2b6e2336e"
      ' "$first" >/dev/null
      ;;
    failure)
      jq -e '
        .jitosol_rebalances == 0 and
        .jitosol_emergencies == 1 and
        .trace_hash == "b2d2eceade8ef89aa0389ad3c8eaca62797551fe26156905ef4f84180748a8dd"
      ' "$first" >/dev/null
      ;;
  esac
done

bundle="$project_dir/replay/bundles/calm-v1.jsonl"
sed 's/"seed":"42"/"seed":"43"/' "$config" >"$temp_dir/unpinned.json"
if "$project_dir/bin/collector" replay \
  --bundle "$bundle" \
  --config "$temp_dir/unpinned.json" >/dev/null 2>&1; then
  printf 'replay accepted a config that does not match the manifest hash\n' >&2
  exit 1
fi

printf 'replay checks passed\n'
