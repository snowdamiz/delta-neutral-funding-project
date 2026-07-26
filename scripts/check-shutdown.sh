#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
holder=$(
  curl -fsS http://127.0.0.1:8080/v1/status |
    jq -r .leaderLeaseHolder
)
case "$holder" in
  "" | *[!A-Za-z0-9:_-]*)
    printf 'collector returned an invalid lease holder\n' >&2
    exit 1
    ;;
esac

start_collector() {
  docker compose --project-directory "$project_dir" start collector >/dev/null
  attempt=0
  until curl -fsS http://127.0.0.1:8080/v1/health >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || return 1
    sleep 1
  done
}

trap start_collector EXIT HUP INT TERM

test "$(
  docker compose --project-directory "$project_dir" exec -T postgres \
    psql -U funding -d funding -Atc \
    "SELECT collector_lease_held('$holder')"
)" = t

docker compose --project-directory "$project_dir" stop --timeout 5 collector >/dev/null

test "$(
  docker inspect --format '{{.State.ExitCode}}' \
    delta-neutral-funding-collector-1
)" = 0
test "$(
  docker compose --project-directory "$project_dir" exec -T postgres \
    psql -U funding -d funding -Atc \
    "SELECT collector_lease_held('$holder')"
)" = f

start_collector
trap - EXIT HUP INT TERM
printf 'collector graceful shutdown check passed\n'
