#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
network=dnf-lease-fencing-check
postgres=dnf-lease-fencing-postgres
collector=dnf-lease-fencing-collector
image=${COLLECTOR_IMAGE:-delta-neutral-funding-collector:latest}

cleanup() {
  docker rm -f "$collector" "$postgres" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

test -z "$(docker ps -aq --filter "name=^/$postgres$")"
test -z "$(docker ps -aq --filter "name=^/$collector$")"
docker network create "$network" >/dev/null
docker run -d --rm \
  --name "$postgres" \
  --network "$network" \
  --tmpfs /var/lib/postgresql/data \
  --mount "type=bind,source=$project_dir/db,target=/db,readonly" \
  -e POSTGRES_DB=funding \
  -e POSTGRES_USER=funding \
  -e POSTGRES_PASSWORD=paper \
  postgres:17-alpine >/dev/null

attempt=0
until docker exec "$postgres" \
  psql -U funding -d funding -Atc "SELECT 1" 2>/dev/null |
  grep -qx 1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || exit 1
  sleep 1
done
docker exec \
  -e PGUSER=funding \
  -e PGDATABASE=funding \
  -e MIGRATION_DIR=/db/migrations \
  "$postgres" /db/migrate.sh >/dev/null

docker run -d --rm \
  --name "$collector" \
  --network "$network" \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:size=16m,mode=1777 \
  -e DATABASE_URL="postgresql://funding:paper@$postgres:5432/funding" \
  -e EXECUTION_MODE=paper \
  -e DEPLOYMENT_ENVIRONMENT=local \
  -e INSTANCE_ID=lease-fencing-check \
  -e LEADER_LEASE_MS=2000 \
  -e LEADER_RENEW_MS=500 \
  -e ADAPTER_HMAC_SECRET=local-paper-only-change-me \
  -e OPERATOR_HMAC_SECRET=local-operator-only-change-me \
  "$image" >/dev/null

attempt=0
until docker exec "$collector" \
  curl --fail --silent http://127.0.0.1:8080/v1/health >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || exit 1
  sleep 1
done
generation=$(
  docker exec "$postgres" \
    psql -U funding -d funding -Atc \
    "SELECT generation FROM leader_leases WHERE lease_name = 'collector'"
)
docker exec "$postgres" \
  psql -U funding -d funding -c \
  "UPDATE leader_leases SET expires_at = clock_timestamp() - interval '1 millisecond' WHERE lease_name = 'collector'" \
  >/dev/null

attempt=0
while docker exec "$collector" \
  curl --fail --silent http://127.0.0.1:8080/v1/health >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 20 ] || exit 1
  sleep 1
done
sleep 3

test "$(
  docker exec "$postgres" \
    psql -U funding -d funding -Atc \
    "SELECT generation FROM leader_leases WHERE lease_name = 'collector'"
)" = "$generation"
docker exec "$postgres" \
  psql -U funding -d funding -Atc "
    SELECT (
      NOT collector_lease_held('lease-fencing-check')
      AND (SELECT pause_entries AND pause_all
           AND reason = 'leader_lease_lost'
           FROM control_state WHERE singleton)
      AND (SELECT count(*) FROM risk_events
           WHERE id = 'leader-lease-lost:lease-fencing-check:$generation') = 1
    )
  " | grep -qx t
test "$(
  docker inspect "$collector" --format '{{.RestartCount}}'
)" = 0

printf 'leader lease fencing checks passed\n'
