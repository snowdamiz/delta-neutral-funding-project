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
    .mesh_commit == "75ee275c3d479eb42693972f41ee5308150be9cd"
  ' "$first" >/dev/null
  case "$scenario" in
    calm)
      jq -e '
        .sol_funding_usd_micros == 92525 and
        .jitosol_funding_usd_micros == 92525 and
        .trace_hash == "958bc37dcf2056845805e07965411bc82f3d07551c84387708fa1b1cfa3c6d2b"
      ' "$first" >/dev/null
      ;;
    volatile)
      jq -e '
        .jitosol_rebalances == 1 and
        .jitosol_basis_lamports == -334000000 and
        .trace_hash == "0da7b7d82558228ddf246bd46755febd74ba15babb26a7222b6112a4cfc9cc8d"
      ' "$first" >/dev/null
      ;;
    liquidity-loss)
      jq -e '
        .sol_emergencies == 0 and
        .jitosol_emergencies == 1 and
        .trace_hash == "8d1d3a027f0bbd2f1751e79c8fe420fed6a981d216dc74bd0ac37becc728c10b"
      ' "$first" >/dev/null
      ;;
    doubled-costs)
      jq -e '
        .sol_execution_fees_usd_micros == 1332362 and
        .jitosol_execution_fees_usd_micros == 1332762 and
        .trace_hash == "683a8f2306d27d778bb87860e452c4bc284ab36655f9625b3a9fbd9a25b10f3a"
      ' "$first" >/dev/null
      ;;
    epoch-boundary)
      jq -e '
        .jitosol_reward_lamports == 2000000 and
        .jitosol_basis_lamports == -2000000 and
        .trace_hash == "8c0383435ce507a86ddb296a853c20585661c84ff0a2c0139f379c8ba21266b0"
      ' "$first" >/dev/null
      ;;
    failure)
      jq -e '
        .jitosol_rebalances == 0 and
        .jitosol_emergencies == 1 and
        .trace_hash == "0d756f74ae845ce17d17b90d49f9a965d80c94c73bd8a0d8e2f73f2873cc252f"
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
