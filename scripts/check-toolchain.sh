#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
mesh_dir="$project_dir/../mesh-lang"
expected_mesh=105b55e1029ceba615161901c84d08a9a64885ea

test "$(git -C "$mesh_dir" rev-parse HEAD)" = "$expected_mesh" || {
  printf 'Mesh checkout does not match the project pin\n' >&2
  exit 1
}
test -z "$(git -C "$mesh_dir" status --porcelain)" || {
  printf 'Mesh checkout has uncommitted changes\n' >&2
  exit 1
}

docker compose \
  --project-directory "$project_dir" \
  --file "$project_dir/compose.yaml" \
  build collector adapter
docker build \
  --file "$project_dir/infra/docker/executor.Dockerfile" \
  --tag delta-neutral-funding-executor:latest \
  "$project_dir"
"$project_dir/scripts/check-shadow.sh"
"$project_dir/scripts/check-replay.sh"

printf 'toolchain adoption checks passed\n'
