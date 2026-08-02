from Packages.BuildIdentity import code_commit, mesh_commit
from Runtime.Registry import accepted_events, rejected_events

pub fn escape_label_value(value :: String) -> String do
  value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
end

fn metadata() -> String do
  "# HELP funding_collector_events_total Protocol events handled by result.\n# TYPE funding_collector_events_total counter\n# HELP funding_collector_build_info Pinned build information.\n# TYPE funding_collector_build_info gauge\n# HELP market_data_age_seconds Age of the latest protocol event.\n# TYPE market_data_age_seconds gauge\n# HELP market_updates_total Persisted protocol events.\n# TYPE market_updates_total counter\n# HELP adapter_to_mesh_latency_seconds Adapter-to-collector persistence latency.\n# TYPE adapter_to_mesh_latency_seconds histogram\n# HELP adapter_connected Whether adapter data is fresh.\n# TYPE adapter_connected gauge\n# HELP adapter_schema_compatible Whether the latest adapter schema is supported.\n# TYPE adapter_schema_compatible gauge\n# HELP funding_rate_hourly Current expected short funding rate.\n# TYPE funding_rate_hourly gauge\n# HELP jitosol_protocol_nav_rate_lamports JitoSOL protocol NAV in lamports per token.\n# TYPE jitosol_protocol_nav_rate_lamports gauge\n# HELP jitosol_executable_buy_rate_lamports Executable JitoSOL buy rate in lamports.\n# TYPE jitosol_executable_buy_rate_lamports gauge\n# HELP jitosol_executable_sell_rate_lamports Executable JitoSOL sell rate in lamports.\n# TYPE jitosol_executable_sell_rate_lamports gauge\n# HELP jitosol_nav_market_deviation_bps JitoSOL NAV-to-market deviation.\n# TYPE jitosol_nav_market_deviation_bps gauge\n# HELP jitosol_exit_depth_usd_micros Executable JitoSOL exit depth in USD micros.\n# TYPE jitosol_exit_depth_usd_micros gauge\n# HELP jitosol_epoch Latest observed JitoSOL epoch.\n# TYPE jitosol_epoch gauge\n# HELP margin_ratio_ppm Current margin ratio.\n# TYPE margin_ratio_ppm gauge\n# HELP liquidation_distance_bps Current liquidation distance.\n# TYPE liquidation_distance_bps gauge\n# HELP risk_events_total Recorded risk events.\n# TYPE risk_events_total counter\n# HELP reconciliation_mismatches_total Reconciliation mismatches.\n# TYPE reconciliation_mismatches_total counter\n# HELP leader_lease_held Whether this collector owns a live writer lease.\n# TYPE leader_lease_held gauge\n# HELP mesh_runtime_up Whether the Mesh runtime is serving.\n# TYPE mesh_runtime_up gauge\n# HELP mesh_outbox_pending Pending Mesh outbox commands.\n# TYPE mesh_outbox_pending gauge\n"
end

fn runtime_metadata() -> String do
  [
    "# HELP mesh_runtime_active_workers Active scheduler workers.\n# TYPE mesh_runtime_active_workers gauge\n",
    "# HELP mesh_runtime_configured_workers Configured scheduler workers.\n# TYPE mesh_runtime_configured_workers gauge\n",
    "# HELP mesh_runtime_runnable_actors Runnable actors.\n# TYPE mesh_runtime_runnable_actors gauge\n",
    "# HELP mesh_runtime_run_queue_messages Messages waiting in the global run queue.\n# TYPE mesh_runtime_run_queue_messages gauge\n",
    "# HELP mesh_actor_mailbox_messages Messages queued across local actors.\n# TYPE mesh_actor_mailbox_messages gauge\n",
    "# HELP mesh_actor_mailbox_depth Observed local actor mailbox depth.\n# TYPE mesh_actor_mailbox_depth gauge\n",
    "# HELP mesh_scheduler_busy_seconds_total Scheduler busy time.\n# TYPE mesh_scheduler_busy_seconds_total counter\n",
    "# HELP mesh_scheduler_idle_seconds_total Scheduler idle time.\n# TYPE mesh_scheduler_idle_seconds_total counter\n",
    "# HELP mesh_http_connections Open HTTP connections.\n# TYPE mesh_http_connections gauge\n",
    "# HELP mesh_http_inflight_requests HTTP requests in service.\n# TYPE mesh_http_inflight_requests gauge\n",
    "# HELP mesh_http_queued_requests HTTP requests awaiting admission.\n# TYPE mesh_http_queued_requests gauge\n",
    "# HELP mesh_http_queued_bytes Bytes awaiting HTTP admission.\n# TYPE mesh_http_queued_bytes gauge\n",
    "# HELP mesh_http_rejected_requests_total HTTP requests rejected by admission control.\n# TYPE mesh_http_rejected_requests_total counter\n",
    "# HELP mesh_http_queue_wait_p95_seconds Runtime HTTP queue-wait p95.\n# TYPE mesh_http_queue_wait_p95_seconds gauge\n",
    "# HELP mesh_http_service_p95_seconds Runtime HTTP service-time p95.\n# TYPE mesh_http_service_p95_seconds gauge\n",
    "# HELP mesh_http_end_to_end_p95_seconds Runtime HTTP end-to-end p95.\n# TYPE mesh_http_end_to_end_p95_seconds gauge\n",
    "# HELP mesh_process_resident_memory_bytes Runtime process resident memory.\n# TYPE mesh_process_resident_memory_bytes gauge\n",
    "# HELP mesh_cpu_available_parallelism Runtime-visible CPU parallelism.\n# TYPE mesh_cpu_available_parallelism gauge\n"
  ]
    |> String.join("")
end

pub fn build_metric(app_commit :: String, mesh_commit :: String) -> String do
  "funding_collector_build_info{app_commit=\"${app_commit}\",mesh_compiler_commit=\"${mesh_commit}\",mesh_runtime_commit=\"${mesh_commit}\",adapter_commit=\"${app_commit}\",schema_version=\"60\",execution_mode=\"paper\"} 1\n"
end

fn formatted_int_sample(series :: String, value :: Int) -> String do
  "${series} ${value}\n"
end

fn formatted_float_sample(series :: String, value :: Float) -> String do
  "${series} ${value}\n"
end

fn metric_sample(
  metrics :: Map<String, Int>,
  key :: String,
  series :: String
) -> String do
  Map.get(metrics, key)
    |2> formatted_int_sample(series)
end

fn seconds_sample(
  metrics :: Map<String, Int>,
  key :: String,
  series :: String
) -> String do
  (Float.from(Map.get(metrics, key)) / 1000000000.0)
    |2> formatted_float_sample(series)
end

fn runtime_metrics(metrics :: Map<String, Int>) -> String do
  [
    "funding_collector_events_total{result=\"accepted\"} ${accepted_events()}\nfunding_collector_events_total{result=\"rejected\"} ${rejected_events()}\nmesh_runtime_up 1\n",
    metrics |> metric_sample("active_workers", "mesh_runtime_active_workers"),
    metrics |> metric_sample("configured_workers", "mesh_runtime_configured_workers"),
    metrics |> metric_sample("runnable_actors", "mesh_runtime_runnable_actors"),
    metrics |> metric_sample("global_run_queue_depth", "mesh_runtime_run_queue_messages"),
    metrics |> metric_sample("mailbox_messages", "mesh_actor_mailbox_messages{actor=\"all\"}"),
    metrics |> metric_sample("mailbox_depth_p50", "mesh_actor_mailbox_depth{actor=\"all\",statistic=\"p50\"}"),
    metrics |> metric_sample("mailbox_depth_p95", "mesh_actor_mailbox_depth{actor=\"all\",statistic=\"p95\"}"),
    metrics |> metric_sample("mailbox_depth_max", "mesh_actor_mailbox_depth{actor=\"all\",statistic=\"max\"}"),
    metrics |> seconds_sample("scheduler_busy_nanoseconds_total", "mesh_scheduler_busy_seconds_total"),
    metrics |> seconds_sample("scheduler_idle_nanoseconds_total", "mesh_scheduler_idle_seconds_total"),
    metrics |> metric_sample("http_connections", "mesh_http_connections"),
    metrics |> metric_sample("http_inflight_requests", "mesh_http_inflight_requests"),
    metrics |> metric_sample("http_queued_requests", "mesh_http_queued_requests"),
    metrics |> metric_sample("http_queued_bytes", "mesh_http_queued_bytes"),
    metrics |> metric_sample("http_rejected_requests_total", "mesh_http_rejected_requests_total"),
    metrics |> seconds_sample("http_queue_wait_p95_nanoseconds", "mesh_http_queue_wait_p95_seconds"),
    metrics |> seconds_sample("http_service_p95_nanoseconds", "mesh_http_service_p95_seconds"),
    metrics |> seconds_sample("http_end_to_end_p95_nanoseconds", "mesh_http_end_to_end_p95_seconds"),
    metrics |> metric_sample("process_resident_memory_bytes", "mesh_process_resident_memory_bytes"),
    metrics |> metric_sample("cpu_available_parallelism", "mesh_cpu_available_parallelism")
  ]
    |> String.join("")
end

fn database_metrics(
  pool :: PoolHandle,
  now_ms :: Int,
  max_age_ms :: Int
) -> String ! String do
  let rows = ("WITH market AS (SELECT COALESCE((SELECT observed_at_ms FROM normalized_events ORDER BY observed_at_ms DESC LIMIT 1), 0)::numeric AS observed_at_ms, COALESCE((SELECT schema_version FROM normalized_events ORDER BY observed_at_ms DESC LIMIT 1), 0) AS schema_version, COALESCE((SELECT canonical_payload->'payload' FROM normalized_events WHERE event_type = 'MarketSnapshot' ORDER BY observed_at_ms DESC LIMIT 1), '{}'::jsonb) AS payload), latency AS (SELECT GREATEST(extract(epoch FROM received_at) * 1000 - observed_at_ms, 0) / 1000 AS value FROM normalized_events), latency_stats AS (SELECT count(*) FILTER (WHERE value <= 0.005) AS le_5, count(*) FILTER (WHERE value <= 0.025) AS le_25, count(*) FILTER (WHERE value <= 0.1) AS le_100, count(*) FILTER (WHERE value <= 0.5) AS le_500, count(*) AS count, COALESCE(sum(value), 0) AS sum FROM latency), severities(severity) AS (VALUES ('info'), ('warning'), ('critical')), risk_counts AS (SELECT severity, count(*) AS count FROM risk_events GROUP BY severity), samples(sort, sample) AS (SELECT 10, 'market_data_age_seconds{source=\"adapter\",type=\"protocol_event\"} ' || (GREATEST($1::numeric - m.observed_at_ms, 0) / 1000)::text FROM market m UNION ALL SELECT 20, 'market_updates_total{source=\"adapter\",type=\"market_snapshot\"} ' || count(*)::text FROM normalized_events WHERE event_type = 'MarketSnapshot' UNION ALL SELECT 21, 'market_updates_total{source=\"adapter\",type=\"funding_settlement\"} ' || count(*)::text FROM normalized_events WHERE event_type = 'FundingSettlement' UNION ALL SELECT 30, 'adapter_to_mesh_latency_seconds_bucket{type=\"protocol_event\",le=\"0.005\"} ' || le_5::text FROM latency_stats UNION ALL SELECT 31, 'adapter_to_mesh_latency_seconds_bucket{type=\"protocol_event\",le=\"0.025\"} ' || le_25::text FROM latency_stats UNION ALL SELECT 32, 'adapter_to_mesh_latency_seconds_bucket{type=\"protocol_event\",le=\"0.1\"} ' || le_100::text FROM latency_stats UNION ALL SELECT 33, 'adapter_to_mesh_latency_seconds_bucket{type=\"protocol_event\",le=\"0.5\"} ' || le_500::text FROM latency_stats UNION ALL SELECT 34, 'adapter_to_mesh_latency_seconds_bucket{type=\"protocol_event\",le=\"+Inf\"} ' || count::text FROM latency_stats UNION ALL SELECT 35, 'adapter_to_mesh_latency_seconds_sum{type=\"protocol_event\"} ' || sum::text FROM latency_stats UNION ALL SELECT 36, 'adapter_to_mesh_latency_seconds_count{type=\"protocol_event\"} ' || count::text FROM latency_stats UNION ALL SELECT 40, 'adapter_connected{adapter=\"protocol-ts\"} ' || CASE WHEN m.observed_at_ms > 0 AND $1::numeric - m.observed_at_ms <= $2::numeric THEN '1' ELSE '0' END FROM market m UNION ALL SELECT 41, 'adapter_schema_compatible{adapter=\"protocol-ts\"} ' || CASE WHEN m.schema_version = 1 THEN '1' ELSE '0' END FROM market m UNION ALL SELECT 42, 'funding_rate_hourly{venue=\"paper\",market=\"SOL-PERP\",kind=\"expected\"} ' || COALESCE((m.payload->>'shortReceiptPpm')::numeric / 1000000, 0)::text FROM market m UNION ALL SELECT 50, 'jitosol_protocol_nav_rate_lamports ' || CASE WHEN COALESCE((m.payload->>'supplyAtoms')::numeric, 0) = 0 THEN '0' ELSE trunc((m.payload->>'totalPoolLamports')::numeric * 1000000000 / (m.payload->>'supplyAtoms')::numeric)::text END FROM market m UNION ALL SELECT 51, 'jitosol_executable_buy_rate_lamports{size=\"paper\"} ' || CASE WHEN COALESCE((m.payload->>'solPriceUsdMicros')::numeric, 0) = 0 THEN '0' ELSE trunc((m.payload->>'jitosolSpotAskPriceUsdMicros')::numeric * 1000000000 / (m.payload->>'solPriceUsdMicros')::numeric)::text END FROM market m UNION ALL SELECT 52, 'jitosol_executable_sell_rate_lamports{size=\"paper\"} ' || CASE WHEN COALESCE((m.payload->>'solPriceUsdMicros')::numeric, 0) = 0 THEN '0' ELSE trunc((m.payload->>'jitosolSpotBidPriceUsdMicros')::numeric * 1000000000 / (m.payload->>'solPriceUsdMicros')::numeric)::text END FROM market m UNION ALL SELECT 53, 'jitosol_nav_market_deviation_bps{size=\"paper\"} ' || CASE WHEN COALESCE((m.payload->>'totalPoolLamports')::numeric, 0) = 0 OR COALESCE((m.payload->>'supplyAtoms')::numeric, 0) = 0 OR COALESCE((m.payload->>'solPriceUsdMicros')::numeric, 0) = 0 THEN '0' ELSE trunc(abs(((m.payload->>'totalPoolLamports')::numeric * 1000000000 / (m.payload->>'supplyAtoms')::numeric) - ((m.payload->>'jitosolSpotBidPriceUsdMicros')::numeric * 1000000000 / (m.payload->>'solPriceUsdMicros')::numeric)) * 10000 / ((m.payload->>'totalPoolLamports')::numeric * 1000000000 / (m.payload->>'supplyAtoms')::numeric))::text END FROM market m UNION ALL SELECT 54, 'jitosol_exit_depth_usd_micros ' || trunc(COALESCE((m.payload->>'jitosolExitDepthLamports')::numeric, 0) * COALESCE((m.payload->>'solPriceUsdMicros')::numeric, 0) / 1000000000)::text FROM market m UNION ALL SELECT 55, 'jitosol_epoch ' || COALESCE(m.payload->>'epoch', '0') FROM market m UNION ALL SELECT 80, 'margin_ratio_ppm ' || CASE WHEN COALESCE((m.payload->>'maintenanceRequirementUsdMicros')::numeric, 0) = 0 THEN '0' ELSE trunc((m.payload->>'collateralUsdMicros')::numeric * 1000000 / (m.payload->>'maintenanceRequirementUsdMicros')::numeric)::text END FROM market m UNION ALL SELECT 81, 'liquidation_distance_bps ' || COALESCE(m.payload->>'liquidationDistanceBps', '0') FROM market m UNION ALL SELECT 82, 'risk_events_total{severity=\"' || s.severity || '\"} ' || COALESCE(r.count, 0)::text FROM severities s LEFT JOIN risk_counts r ON r.severity = s.severity UNION ALL SELECT 83, 'reconciliation_mismatches_total{type=\"paper\"} ' || count(*)::text FROM reconciliations WHERE result <> 'matched' UNION ALL SELECT 90, 'leader_lease_held ' || CASE WHEN EXISTS (SELECT 1 FROM leader_leases WHERE lease_name = 'collector' AND holder_instance_id = $3 AND expires_at > clock_timestamp()) THEN '1' ELSE '0' END UNION ALL SELECT 91, 'mesh_outbox_pending ' || count(*)::text FROM outbox_commands WHERE processed_at IS NULL) SELECT COALESCE(string_agg(sample, E'\\n' ORDER BY sort, sample), '') || E'\\n' AS body FROM samples"
    |2> Pool.query(pool, [
      "${now_ms}",
      "${max_age_ms}",
      Env.get("INSTANCE_ID", "")
    ])) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid metrics snapshot")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end

pub fn render(
  pool :: PoolHandle,
  now_ms :: Int,
  max_age_ms :: Int
) -> String ! String do
  Ok(
    metadata()
      <> runtime_metadata()
      <> (mesh_commit()
        |> escape_label_value
        |2> build_metric(
          code_commit() |> escape_label_value
        ))
      <> (Cluster.telemetry() |> runtime_metrics)
      <> ((now_ms |2> database_metrics(pool, max_age_ms)) ?)
  )
end
