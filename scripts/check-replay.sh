#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temp_dir=$(mktemp -d)
trap 'find "$temp_dir" -depth -delete' EXIT HUP INT TERM

config="$project_dir/replay/configs/baseline-v1.json"

for scenario in calm volatile liquidity-loss epoch-boundary failure; do
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
    .mesh_commit == "ed8dc2b8254ab51d4ebefed43fe4f4d44a128d2a"
  ' "$first" >/dev/null
  case "$scenario" in
    calm)
      jq -e '
        .sol_funding_usd_micros == 92525 and
        .jitosol_funding_usd_micros == 92525 and
        .trace_hash == "4284bb84e784e9ad28c1a2baae1e7762181606b27a044a2a1e5bc32ff0b5002a"
      ' "$first" >/dev/null
      ;;
    volatile)
      jq -e '
        .jitosol_rebalances == 1 and
        .jitosol_basis_lamports == -334000000 and
        .trace_hash == "4a2cde515e35d92a02bb722de638258853529c4a7b8732a1c48843e98e44b530"
      ' "$first" >/dev/null
      ;;
    liquidity-loss)
      jq -e '
        .sol_emergencies == 0 and
        .jitosol_emergencies == 1 and
        .trace_hash == "83ddc654b3199c724c65a67149261422965751c69e25df9f218f0f51c8cc53e0"
      ' "$first" >/dev/null
      ;;
    epoch-boundary)
      jq -e '
        .jitosol_reward_lamports == 2000000 and
        .jitosol_basis_lamports == -2000000 and
        .trace_hash == "11f222a7349bacd1b05cab33b324705f23aa5456144bc99ace2ec3d139c94c22"
      ' "$first" >/dev/null
      ;;
    failure)
      jq -e '
        .jitosol_rebalances == 0 and
        .jitosol_emergencies == 1 and
        .trace_hash == "5ca1c040728222c855fbaf9f5be9b439eca541320c180331aab987ac27361013"
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
