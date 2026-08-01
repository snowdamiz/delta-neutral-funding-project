#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
mesh_dir="$project_dir/../mesh-lang"
expected_mesh=c5379f8d00990df18248e4bf2d53bbb1d04868fb
code_commit=$(git -C "$project_dir" rev-parse HEAD)
mesh_tag=$(printf '%.7s' "$expected_mesh")

test "$(git -C "$mesh_dir" rev-parse HEAD)" = "$expected_mesh" || {
  printf 'Mesh checkout does not match the project pin\n' >&2
  exit 1
}
test -z "$(git -C "$mesh_dir" status --porcelain)" || {
  printf 'Mesh checkout has uncommitted changes\n' >&2
  exit 1
}
test -z "$(git -C "$project_dir" status --porcelain)" || {
  printf 'Project checkout has uncommitted changes\n' >&2
  exit 1
}

CODE_COMMIT=$code_commit docker compose \
  --project-directory "$project_dir" \
  --file "$project_dir/compose.yaml" \
  build collector adapter
docker image tag \
  delta-neutral-funding-collector:latest \
  "delta-neutral-funding-collector:$code_commit-$mesh_tag"
docker image tag \
  delta-neutral-funding-adapter:latest \
  "delta-neutral-funding-adapter:$code_commit"
"$project_dir/scripts/check-lease-fencing.sh"
"$project_dir/scripts/check-database.sh"

printf 'toolchain adoption checks passed\n'
