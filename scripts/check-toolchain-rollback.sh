#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
candidate_image=${CANDIDATE_COLLECTOR_IMAGE:-delta-neutral-funding-collector:latest}
rollback_image=${ROLLBACK_COLLECTOR_IMAGE:-delta-neutral-funding-collector:1fced7609881ddacf8e3d198adf7d9096f0bd984-728f534}
candidate_mesh=c5379f8d00990df18248e4bf2d53bbb1d04868fb
rollback_mesh=728f534e0500f90a11cbe8184befb711664280de
rollback_code=1fced7609881ddacf8e3d198adf7d9096f0bd984
temp_dir=$(mktemp -d)
trap 'find "$temp_dir" -depth -delete' EXIT HUP INT TERM

test -z "$(git -C "$project_dir" status --porcelain)"
test "$(
  docker image inspect "$candidate_image" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
)" = "$(git -C "$project_dir" rev-parse HEAD)"
test "$(
  docker image inspect "$candidate_image" \
    --format '{{index .Config.Labels "org.mesh-lang.revision"}}'
)" = "$candidate_mesh"
test "$(
  docker image inspect "$rollback_image" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
)" = "$rollback_code"
test "$(
  docker image inspect "$rollback_image" \
    --format '{{index .Config.Labels "org.mesh-lang.revision"}}'
)" = "$rollback_mesh"

config="$project_dir/replay/configs/baseline-v1.json"
for scenario in calm volatile liquidity-loss doubled-costs epoch-boundary failure; do
  candidate_bundle="$project_dir/replay/bundles/$scenario-v1.jsonl"
  rollback_bundle="$temp_dir/$scenario-v1.jsonl"
  candidate_report="$temp_dir/$scenario-candidate.json"
  rollback_report="$temp_dir/$scenario-rollback.json"
  candidate_economics="$temp_dir/$scenario-candidate-economics.json"
  rollback_economics="$temp_dir/$scenario-rollback-economics.json"

  test "$(
    sed -n '1p' "$candidate_bundle" |
      jq -r .meshCommit
  )" = "$candidate_mesh"
  sed "1s/$candidate_mesh/$rollback_mesh/" \
    "$candidate_bundle" >"$rollback_bundle"
  test "$(
    sed -n '1p' "$rollback_bundle" |
      jq -r .meshCommit
  )" = "$rollback_mesh"

  COLLECTOR_IMAGE=$candidate_image \
    "$project_dir/bin/collector" replay \
      --bundle "$candidate_bundle" \
      --config "$config" >"$candidate_report"
  COLLECTOR_IMAGE=$rollback_image \
    "$project_dir/bin/collector" replay \
      --bundle "$rollback_bundle" \
      --config "$config" >"$rollback_report"

  jq -e --arg mesh "$candidate_mesh" \
    '.mesh_commit == $mesh' "$candidate_report" >/dev/null
  jq -e --arg mesh "$rollback_mesh" \
    '.mesh_commit == $mesh' "$rollback_report" >/dev/null
  jq -S 'del(.mesh_commit)' "$candidate_report" >"$candidate_economics"
  jq -S 'del(.mesh_commit)' "$rollback_report" >"$rollback_economics"
  cmp "$candidate_economics" "$rollback_economics"
done

printf 'toolchain rollback replay checks passed\n'
