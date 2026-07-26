#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
prometheus_url=${PROMETHEUS_URL:-http://127.0.0.1:9090}
collector_url=${COLLECTOR_URL:-http://127.0.0.1:8080}
soak=$("$project_dir/scripts/soak-report.sh")
elapsed_ms=$(printf '%s' "$soak" | jq -er '.elapsedMs | tonumber')
window_seconds=$(( (elapsed_ms + 999) / 1000 ))
test "$window_seconds" -gt 0 || window_seconds=1

query_value() {
  curl -fsSG "$prometheus_url/api/v1/query" \
    --data-urlencode "query=$1" |
    jq -er '
      if .status == "success" and (.data.result | length) == 1
      then .data.result[0].value[1] | tonumber
      else error("Prometheus query returned no unique value")
      end
    '
}

mesh_runtime_minimum_up=$(query_value \
  "min(min_over_time(mesh_runtime_up[${window_seconds}s]))")
maximum_resident_memory_bytes=$(query_value \
  "max(max_over_time(mesh_process_resident_memory_bytes[${window_seconds}s]))")
maximum_mailbox_depth=$(query_value \
  "max(max_over_time(mesh_actor_mailbox_depth{statistic=\"max\"}[${window_seconds}s]))")
maximum_mailbox_messages=$(query_value \
  "max(max_over_time(mesh_actor_mailbox_messages[${window_seconds}s]))")
maximum_run_queue_messages=$(query_value \
  "max(max_over_time(mesh_runtime_run_queue_messages[${window_seconds}s]))")
maximum_outbox_pending=$(query_value \
  "max(max_over_time(mesh_outbox_pending[${window_seconds}s]))")
scheduler_counter_resets=$(query_value \
  "sum(resets(mesh_scheduler_busy_seconds_total[${window_seconds}s]))")
http_rejected_requests=$(query_value \
  "sum(increase(mesh_http_rejected_requests_total[${window_seconds}s]))")
postgres_database_bytes=$(docker compose --project-directory "$project_dir" \
  exec -T postgres psql -U funding -d funding -Atc \
  "SELECT pg_database_size(current_database())")
prometheus_storage_kib=$(docker compose --project-directory "$project_dir" \
  exec -T prometheus du -sk /prometheus | awk '{print $1}')
collector_id=$(docker compose --project-directory "$project_dir" ps -q collector)
collector_restart_count=$(docker inspect "$collector_id" --format '{{.RestartCount}}')
build=$(curl -fsS "$collector_url/v1/build")

jq -n \
  --arg status "$(printf '%s' "$soak" | jq -er .status)" \
  --arg appCommit "$(printf '%s' "$build" | jq -er .codeCommit)" \
  --arg meshCommit "$(printf '%s' "$build" | jq -er .meshCommit)" \
  --arg firstObservedAtMs "$(printf '%s' "$soak" | jq -er .firstObservedAtMs)" \
  --arg lastObservedAtMs "$(printf '%s' "$soak" | jq -er .lastObservedAtMs)" \
  --argjson windowSeconds "$window_seconds" \
  --argjson meshRuntimeMinimumUp "$mesh_runtime_minimum_up" \
  --argjson maximumResidentMemoryBytes "$maximum_resident_memory_bytes" \
  --argjson maximumMailboxDepth "$maximum_mailbox_depth" \
  --argjson maximumMailboxMessages "$maximum_mailbox_messages" \
  --argjson maximumRunQueueMessages "$maximum_run_queue_messages" \
  --argjson maximumOutboxPending "$maximum_outbox_pending" \
  --argjson schedulerCounterResets "$scheduler_counter_resets" \
  --argjson httpRejectedRequests "$http_rejected_requests" \
  --argjson postgresDatabaseBytes "$postgres_database_bytes" \
  --argjson prometheusStorageBytes "$((prometheus_storage_kib * 1024))" \
  --argjson collectorRestartCount "$collector_restart_count" \
  '{
    status: $status,
    appCommit: $appCommit,
    meshCommit: $meshCommit,
    firstObservedAtMs: $firstObservedAtMs,
    lastObservedAtMs: $lastObservedAtMs,
    windowSeconds: $windowSeconds,
    meshRuntimeMinimumUp: $meshRuntimeMinimumUp,
    maximumResidentMemoryBytes: $maximumResidentMemoryBytes,
    maximumMailboxDepth: $maximumMailboxDepth,
    maximumMailboxMessages: $maximumMailboxMessages,
    maximumRunQueueMessages: $maximumRunQueueMessages,
    maximumOutboxPending: $maximumOutboxPending,
    schedulerCounterResets: $schedulerCounterResets,
    httpRejectedRequests: $httpRejectedRequests,
    postgresDatabaseBytes: $postgresDatabaseBytes,
    prometheusStorageBytes: $prometheusStorageBytes,
    collectorRestartCount: $collectorRestartCount
  }'
