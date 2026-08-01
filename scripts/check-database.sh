#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
database_container=dnf-postgres-contract-check

cleanup() {
  docker stop "$database_container" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

test -z "$(docker ps -aq --filter "name=^/$database_container$")"
docker run -d --rm \
  --name "$database_container" \
  --network none \
  --memory 1g \
  --pids-limit 256 \
  --tmpfs /var/lib/postgresql/data \
  --mount "type=bind,source=$project_dir/db,target=/db,readonly" \
  -e POSTGRES_DB=funding \
  -e POSTGRES_USER=funding \
  -e POSTGRES_PASSWORD=paper \
  postgres:17-alpine >/dev/null

attempt=0
ready_checks=0
until [ "$ready_checks" -eq 2 ]; do
  if docker exec "$database_container" \
    psql -U funding -d funding -Atc "SELECT 1" 2>/dev/null |
    grep -qx 1; then
    ready_checks=$((ready_checks + 1))
  else
    ready_checks=0
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || exit 1
  sleep 1
done

docker exec \
  -e PGUSER=funding \
  -e PGDATABASE=funding \
  -e MIGRATION_DIR=/db/migrations \
  "$database_container" \
  /db/migrate.sh >/dev/null

for test_path in "$project_dir"/db/tests/*.sql; do
  docker exec "$database_container" \
    psql -U funding -d funding --set=ON_ERROR_STOP=1 \
    --file "/db/tests/${test_path##*/}" >/dev/null
  printf 'passed %s\n' "${test_path##*/}"
done

test "$(
  docker exec "$database_container" \
    psql -U funding -d funding -Atc "SELECT max(version) FROM schema_meta"
)" = 48
printf 'database migration and contract checks passed\n'
