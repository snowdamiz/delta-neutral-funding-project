#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
base_url=${1:-http://127.0.0.1:8080}
metrics_file=$(mktemp)
trap 'rm -f "$metrics_file"' EXIT HUP INT TERM

curl -fsS -D "$metrics_file.headers" "$base_url/metrics" >"$metrics_file"
trap 'rm -f "$metrics_file" "$metrics_file.headers"' EXIT HUP INT TERM
grep -qi '^content-type: text/plain; version=0.0.4; charset=utf-8' \
  "$metrics_file.headers"
test "$(tail -c 1 "$metrics_file" | wc -l | tr -d ' ')" = 1
build=$(curl -fsS "$base_url/v1/build")
app_commit=$(printf '%s' "$build" | jq -r .codeCommit)
mesh_commit=$(printf '%s' "$build" | jq -r .meshCommit)
grep -q "funding_collector_build_info{app_commit=\"$app_commit\",mesh_compiler_commit=\"$mesh_commit\",mesh_runtime_commit=\"$mesh_commit\",adapter_commit=\"$app_commit\",schema_version=\"54\",execution_mode=\"paper\"} 1" \
  "$metrics_file"

for metric in \
  funding_collector_build_info \
  market_data_age_seconds \
  adapter_to_mesh_latency_seconds_bucket \
  adapter_connected \
  jitosol_protocol_nav_rate_lamports \
  jitosol_exit_depth_usd_micros \
  margin_ratio_ppm \
  liquidation_distance_bps \
  risk_events_total \
  reconciliation_mismatches_total \
  leader_lease_held \
  mesh_runtime_up \
  mesh_runtime_active_workers \
  mesh_actor_mailbox_messages \
  mesh_scheduler_busy_seconds_total \
  mesh_http_inflight_requests \
  mesh_http_rejected_requests_total \
  mesh_process_resident_memory_bytes \
  mesh_outbox_pending
do
  grep -q "^$metric" "$metrics_file"
done

docker run --rm -i --entrypoint promtool prom/prometheus:v3.5.0 \
  check metrics <"$metrics_file"
docker run --rm \
  --entrypoint promtool \
  --mount "type=bind,source=$project_dir/infra/prometheus,target=/prometheus-config,readonly" \
  prom/prometheus:v3.5.0 \
  check config /prometheus-config/prometheus.yml
docker run --rm \
  --entrypoint promtool \
  --mount "type=bind,source=$project_dir/infra/prometheus,target=/prometheus-config,readonly" \
  --workdir /prometheus-config \
  prom/prometheus:v3.5.0 \
  test rules rules.test.yml

jq -e '
  ([.panels[].title] | length >= 5) and
  ([
    "Margin", "Exit liquidity", "Adapter health",
    "Mesh runtime", "Build identity"
  ] - [.panels[].title] | length == 0)
' "$project_dir/infra/grafana/dashboards/funding-collector.json" >/dev/null
curl -fsS http://127.0.0.1:9090/api/v1/rules |
  jq -e '
    [.data.groups[].rules[].name] as $rules |
    all([
      "CollectorUnavailable", "WriterLeaseLost", "CriticalMargin",
      "CriticalLiquidationDistance", "AdapterStale",
      "ReconciliationMismatch", "CriticalRiskEvent"
    ][]; $rules | index(.) != null)
  ' >/dev/null
curl -fsS http://127.0.0.1:9090/api/v1/status/flags |
  jq -e '
    .data["storage.tsdb.retention.time"] == "5w" and
    .data["storage.tsdb.retention.size"] == "2GiB"
  ' >/dev/null
"$project_dir/scripts/runtime-stability-report.sh" |
  jq -e '
    .windowSeconds == (((.elapsedMs | tonumber) + (.staleForMs | tonumber) + 999) / 1000 | floor) and
    .meshRuntimeMinimumUp == 1 and
    .maximumResidentMemoryBytes > 0 and
    .maximumMailboxDepth >= 0 and
    .maximumMailboxMessages >= 0 and
    .maximumRunQueueMessages >= 0 and
    .maximumOutboxPending >= 0 and
    .schedulerCounterResets >= 0 and
    .httpRejectedRequests >= 0 and
    .postgresDatabaseBytes > 0 and
    .prometheusStorageBytes > 0 and
    .collectorRestartCount >= 0
  ' >/dev/null

printf 'observability checks passed\n'
