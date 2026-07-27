#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
mesh_dir="$project_dir/../mesh-lang"
expected_mesh=2d77889767beb5c2b75bc8fda3956c7d43f116aa
project_commit=$(git -C "$project_dir" rev-parse HEAD)
mesh_tag=$(printf '%.7s' "$expected_mesh")
collector=delta-neutral-funding-collector:latest
adapter=delta-neutral-funding-adapter:latest
executor=delta-neutral-funding-executor:latest
trivy=aquasec/trivy@sha256:cffe3f5161a47a6823fbd23d985795b3ed72a4c806da4c4df16266c02accdd6f
work_dir=$(mktemp -d)
trivy_cache=dnf-trivy-cache-$$
docker volume create "$trivy_cache" >/dev/null
trap 'docker volume rm "$trivy_cache" >/dev/null 2>&1 || true; rm -rf "$work_dir"' EXIT HUP INT TERM

test "$(git -C "$mesh_dir" rev-parse HEAD)" = "$expected_mesh"
test -z "$(git -C "$mesh_dir" status --porcelain)"

docker compose --project-directory "$project_dir" --file "$project_dir/compose.yaml" \
  config --format json >"$work_dir/compose.json"
jq -e '
  . as $config |
  (.services.postgres.ports == null) and
  (.services.postgres.networks | keys == ["database"]) and
  (.services.adapter.networks | keys == ["ingest"]) and
  (.services.collector.environment.EXECUTION_MODE == "paper") and
  (.services.collector.environment.DEPLOYMENT_ENVIRONMENT == "local") and
  (.services | has("executor") | not) and
  all(.services.collector, .services.adapter;
    .read_only and
    (.cap_drop | index("ALL") != null) and
    (.security_opt | index("no-new-privileges:true") != null)
  ) and
  all(["postgres", "migrate", "collector", "adapter", "prometheus", "grafana"][];
    ($config.services[.].logging.driver == "local") and
    ($config.services[.].logging.options."max-size" == "10m") and
    ($config.services[.].logging.options."max-file" == "3") and
    ($config.services[.].mem_limit > 0) and
    ($config.services[.].pids_limit > 0)
  )
' "$work_dir/compose.json" >/dev/null

test "$(docker image inspect --format '{{.Config.User}}' "$collector")" = "collector:collector"
test "$(docker image inspect --format '{{.Config.User}}' "$adapter")" = "65532:65532"
test "$(docker image inspect --format '{{.Config.User}}' "$executor")" = "65532:65532"
for image in "$collector" "$adapter" "$executor"; do
  test "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")" = "$project_commit"
done
test "$(docker image inspect --format '{{index .Config.Labels "org.mesh-lang.revision"}}' "$collector")" = "$expected_mesh"
if docker image inspect \
  --format '{{range .Config.Env}}{{println .}}{{end}}' "$collector" |
  grep -Eq '^(CODE_COMMIT|MESH_COMMIT)='; then
  printf 'collector exposes overridable release identity variables\n' >&2
  exit 1
fi
docker image inspect "delta-neutral-funding-collector:$project_commit-$mesh_tag" >/dev/null
docker image inspect "delta-neutral-funding-adapter:$project_commit" >/dev/null
docker image inspect "delta-neutral-funding-executor:$project_commit" >/dev/null

for image in "$collector" "$adapter" "$executor"; do
  name=${image%%:*}
  docker scout sbom "local://$image" --format cyclonedx --output "$work_dir/$name.cdx.json"
  jq -e '.bomFormat == "CycloneDX" and (.components | length > 0)' \
    "$work_dir/$name.cdx.json" >/dev/null
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$trivy_cache:/root/.cache/" \
    "$trivy" image --quiet --scanners vuln --severity HIGH,CRITICAL \
    --ignore-unfixed --exit-code 1 "$image"
done

if docker run --rm --network none \
  -e EXECUTION_MODE=live \
  -e DATABASE_URL=postgresql://unused \
  "$collector"; then
  printf 'collector accepted live execution mode\n' >&2
  exit 1
fi
if docker run --rm --network none \
  -e EXECUTION_MODE=paper \
  -e DEPLOYMENT_ENVIRONMENT=paper \
  -e ADAPTER_HMAC_SECRET=local-paper-only-change-me \
  -e OPERATOR_HMAC_SECRET=local-operator-only-change-me \
  -e DATABASE_URL=postgresql://unused \
  "$collector"; then
  printf 'collector accepted local secrets outside local deployment\n' >&2
  exit 1
fi
if docker run --rm --network none \
  -e EXECUTION_MODE=paper \
  -e DEPLOYMENT_ENVIRONMENT=local \
  -e ADAPTER_HMAC_SECRET=local-paper-only-change-me \
  -e OPERATOR_HMAC_SECRET=local-operator-only-change-me \
  "$collector"; then
  printf 'collector accepted an empty database URL\n' >&2
  exit 1
fi

printf 'security checks passed\n'
