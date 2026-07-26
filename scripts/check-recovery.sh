#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temp_dir=$(mktemp -d)
restore_container=dnf-postgres-restore-check

cleanup() {
  docker stop "$restore_container" >/dev/null 2>&1 || true
  find "$temp_dir" -depth -delete
}
trap cleanup EXIT HUP INT TERM

test -z "$(docker ps -aq --filter "name=^/$restore_container$")"
cd "$project_dir"

docker compose restart collector >/dev/null
attempt=0
until curl -fsS http://127.0.0.1:8080/v1/health >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 30 ] || exit 1
  sleep 1
done

test "$(
  docker compose exec -T postgres \
    psql -U funding -d funding -Atc \
    "SELECT schema_version FROM build_manifests WHERE id = 'local-paper-build'"
)" = 24
curl -fsS http://127.0.0.1:8080/v1/status |
  jq -e '.executionMode == "paper" and .signerReachable == false' >/dev/null

docker compose exec -T postgres \
  pg_dump -U funding -d funding --format=custom >"$temp_dir/funding.dump"
test -s "$temp_dir/funding.dump"

docker run -d --rm \
  --name "$restore_container" \
  --tmpfs /var/lib/postgresql/data \
  -e POSTGRES_DB=funding \
  -e POSTGRES_USER=funding \
  -e POSTGRES_PASSWORD=paper \
  postgres:17-alpine >/dev/null
attempt=0
ready_checks=0
until [ "$ready_checks" -eq 2 ]; do
  if docker exec "$restore_container" \
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

docker run --rm \
  --network "container:$restore_container" \
  -e PGHOST=127.0.0.1 \
  -e PGUSER=funding \
  -e PGDATABASE=funding \
  -e PGPASSWORD=paper \
  -v "$temp_dir/funding.dump:/funding.dump:ro" \
  postgres:17-alpine \
  pg_restore --exit-on-error --no-owner --no-privileges \
    --dbname=funding /funding.dump

docker exec "$restore_container" \
  psql -U funding -d funding -Atc "
    SELECT (
      (SELECT max(version) FROM schema_meta) = 24
      AND (SELECT schema_version FROM build_manifests
           WHERE id = 'local-paper-build') = 24
      AND (SELECT count(*) FROM portfolio_runs
           WHERE strategy_run_id = 'local-paper-run') = 4
      AND (SELECT count(*) FROM ledger_batches) >= 4
      AND (SELECT count(*) FROM shadow_execution_results) >= 2
    )
  " | grep -qx t

restore_result=$(
  docker exec "$restore_container" \
    psql -U funding -d funding -Atc \
    "SELECT record_paper_reconciliation(
       'reconciliation:restore-drill',
       'database_restore_drill'
     )->>'result'"
)
case "$restore_result" in
  matched | recovery_required) ;;
  *)
    printf 'restored database did not reconcile: %s\n' "$restore_result" >&2
    exit 1
    ;;
esac

printf 'collector restart and PostgreSQL restore/reconciliation checks passed\n'
