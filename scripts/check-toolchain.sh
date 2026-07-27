#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
mesh_dir="$project_dir/../mesh-lang"
expected_mesh=c5c75c405e4141eb2dc5a25e8ed638b75ccbd8c9
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
docker build \
  --sbom=true \
  --provenance=mode=max \
  --build-arg "CODE_COMMIT=$code_commit" \
  --file "$project_dir/infra/docker/executor.Dockerfile" \
  --tag delta-neutral-funding-executor:latest \
  "$project_dir"
docker image tag \
  delta-neutral-funding-collector:latest \
  "delta-neutral-funding-collector:$code_commit-$mesh_tag"
docker image tag \
  delta-neutral-funding-adapter:latest \
  "delta-neutral-funding-adapter:$code_commit"
docker image tag \
  delta-neutral-funding-executor:latest \
  "delta-neutral-funding-executor:$code_commit"
"$project_dir/scripts/check-shadow.sh"
"$project_dir/scripts/check-replay.sh"
"$project_dir/scripts/check-database.sh"

printf 'toolchain adoption checks passed\n'
