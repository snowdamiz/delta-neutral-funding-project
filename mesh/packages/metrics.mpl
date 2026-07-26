from Runtime.Registry import accepted_events, rejected_events

pub fn escape_label_value(value :: String) -> String do
  value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
end

fn metadata() -> String do
  "# HELP funding_collector_events_total Protocol events handled by result.\n# TYPE funding_collector_events_total counter\n# HELP funding_collector_build_info Pinned build information.\n# TYPE funding_collector_build_info gauge\n# HELP market_data_age_seconds Age of the latest protocol event.\n# TYPE market_data_age_seconds gauge\n# HELP market_updates_total Persisted protocol events.\n# TYPE market_updates_total counter\n# HELP adapter_to_mesh_latency_seconds Adapter-to-collector persistence latency.\n# TYPE adapter_to_mesh_latency_seconds histogram\n# HELP adapter_connected Whether adapter data is fresh.\n# TYPE adapter_connected gauge\n# HELP adapter_schema_compatible Whether the latest adapter schema is supported.\n# TYPE adapter_schema_compatible gauge\n# HELP funding_rate_hourly Current expected short funding rate.\n# TYPE funding_rate_hourly gauge\n# HELP spot_perp_basis_bps Current spot-to-perpetual basis.\n# TYPE spot_perp_basis_bps gauge\n# HELP jitosol_protocol_nav_rate_lamports JitoSOL protocol NAV in lamports per token.\n# TYPE jitosol_protocol_nav_rate_lamports gauge\n# HELP jitosol_executable_buy_rate_lamports Executable JitoSOL buy rate in lamports.\n# TYPE jitosol_executable_buy_rate_lamports gauge\n# HELP jitosol_executable_sell_rate_lamports Executable JitoSOL sell rate in lamports.\n# TYPE jitosol_executable_sell_rate_lamports gauge\n# HELP jitosol_nav_market_deviation_bps JitoSOL NAV-to-market deviation.\n# TYPE jitosol_nav_market_deviation_bps gauge\n# HELP jitosol_exit_depth_usd_micros Executable JitoSOL exit depth in USD micros.\n# TYPE jitosol_exit_depth_usd_micros gauge\n# HELP jitosol_reward_accrual_usd_micros Recorded JitoSOL reward accrual in USD micros.\n# TYPE jitosol_reward_accrual_usd_micros gauge\n# HELP jitosol_basis_pnl_usd_micros Recorded JitoSOL basis P&L in USD micros.\n# TYPE jitosol_basis_pnl_usd_micros gauge\n# HELP jitosol_epoch Latest observed JitoSOL epoch.\n# TYPE jitosol_epoch gauge\n# HELP strategy_state Current portfolio state.\n# TYPE strategy_state gauge\n# HELP opportunity_expected_net_usd_micros Latest expected net carry.\n# TYPE opportunity_expected_net_usd_micros gauge\n# HELP position_spot_equivalent_sol_atoms Spot-equivalent SOL atoms.\n# TYPE position_spot_equivalent_sol_atoms gauge\n# HELP position_perp_sol_atoms Perpetual short SOL atoms.\n# TYPE position_perp_sol_atoms gauge\n# HELP position_net_delta_sol_atoms Net delta in SOL atoms.\n# TYPE position_net_delta_sol_atoms gauge\n# HELP position_delta_bps Absolute portfolio delta.\n# TYPE position_delta_bps gauge\n# HELP position_gross_notional_usd_micros Gross portfolio notional in USD micros.\n# TYPE position_gross_notional_usd_micros gauge\n# HELP comparison_incremental_jitosol_pnl_usd_micros Incremental JitoSOL P&L versus SOL control.\n# TYPE comparison_incremental_jitosol_pnl_usd_micros gauge\n# HELP orders_total Recorded orders.\n# TYPE orders_total counter\n# HELP partial_fills_total Recorded partial fills.\n# TYPE partial_fills_total counter\n# HELP shadow_paper_fill_error_bps Latest shadow-to-paper price error.\n# TYPE shadow_paper_fill_error_bps gauge\n# HELP shadow_executor_results Shadow executor results.\n# TYPE shadow_executor_results gauge\n# HELP executor_policy_rejections_total Shadow executor policy rejections.\n# TYPE executor_policy_rejections_total counter\n# HELP margin_ratio_ppm Current margin ratio.\n# TYPE margin_ratio_ppm gauge\n# HELP liquidation_distance_bps Current liquidation distance.\n# TYPE liquidation_distance_bps gauge\n# HELP risk_events_total Recorded risk events.\n# TYPE risk_events_total counter\n# HELP reconciliation_mismatches_total Reconciliation mismatches.\n# TYPE reconciliation_mismatches_total counter\n# HELP funding_received_usd_micros Realized funding in USD micros.\n# TYPE funding_received_usd_micros gauge\n# HELP spot_fees_usd_micros_total Recorded spot fees in USD micros.\n# TYPE spot_fees_usd_micros_total counter\n# HELP perp_fees_usd_micros_total Recorded perpetual fees in USD micros.\n# TYPE perp_fees_usd_micros_total counter\n# HELP net_pnl_usd_micros Net recorded P&L in USD micros.\n# TYPE net_pnl_usd_micros gauge\n# HELP leader_lease_held Whether this collector owns a live writer lease.\n# TYPE leader_lease_held gauge\n# HELP mesh_runtime_up Whether the Mesh runtime is serving.\n# TYPE mesh_runtime_up gauge\n# HELP mesh_outbox_pending Pending Mesh outbox commands.\n# TYPE mesh_outbox_pending gauge\n"
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

fn build_metric(app_commit :: String, mesh_commit :: String) -> String do
  "funding_collector_build_info{app_commit=\"${app_commit}\",mesh_compiler_commit=\"${mesh_commit}\",mesh_runtime_commit=\"${mesh_commit}\",adapter_commit=\"${app_commit}\",executor_commit=\"${app_commit}\",schema_version=\"26\",execution_mode=\"paper\"} 1\n"
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
  let rows = ("WITH known_portfolios(id) AS (VALUES ('local-sol-control'), ('local-jitosol-carry'), ('local-sync-sol-control'), ('local-sync-jitosol-carry')), portfolio_base AS (SELECT p.id, p.variant::text AS variant, p.state::text AS state FROM portfolio_runs p JOIN known_portfolios k ON k.id = p.id WHERE p.strategy_run_id = 'local-paper-run'), market AS (SELECT COALESCE((SELECT observed_at_ms FROM normalized_events ORDER BY observed_at_ms DESC LIMIT 1), 0)::numeric AS observed_at_ms, COALESCE((SELECT schema_version FROM normalized_events ORDER BY observed_at_ms DESC LIMIT 1), 0) AS schema_version, COALESCE((SELECT canonical_payload->'payload' FROM normalized_events WHERE event_type = 'MarketSnapshot' ORDER BY observed_at_ms DESC LIMIT 1), '{}'::jsonb) AS payload), latency AS (SELECT GREATEST(extract(epoch FROM received_at) * 1000 - observed_at_ms, 0) / 1000 AS value FROM normalized_events), latency_stats AS (SELECT count(*) FILTER (WHERE value <= 0.005) AS le_5, count(*) FILTER (WHERE value <= 0.025) AS le_25, count(*) FILTER (WHERE value <= 0.1) AS le_100, count(*) FILTER (WHERE value <= 0.5) AS le_500, count(*) AS count, COALESCE(sum(value), 0) AS sum FROM latency), balances AS (SELECT p.id, p.variant, p.state, COALESCE(sum(CASE WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'BUY' THEN f.quantity_atoms::numeric WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'SELL' THEN -f.quantity_atoms::numeric ELSE 0 END), 0) AS spot_quantity, COALESCE(sum(CASE WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'SELL' THEN f.quantity_atoms::numeric WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'BUY' THEN -f.quantity_atoms::numeric ELSE 0 END), 0) AS perp_short FROM portfolio_base p LEFT JOIN fills f ON f.portfolio_run_id = p.id LEFT JOIN orders o ON o.id = f.order_id LEFT JOIN execution_intents ei ON ei.id = o.intent_id GROUP BY p.id, p.variant, p.state), positions AS (SELECT b.id, b.variant, b.state, trunc(b.spot_quantity * CASE WHEN b.variant = 'sol_control' THEN 1 ELSE COALESCE((m.payload->>'jitosolSpotBidPriceUsdMicros')::numeric / NULLIF((m.payload->>'solPriceUsdMicros')::numeric, 0), 0) END) AS spot_equivalent, b.perp_short, COALESCE((m.payload->>'solPriceUsdMicros')::numeric, 0) AS sol_price FROM balances b CROSS JOIN market m), latest_decisions AS (SELECT DISTINCT ON (variant) variant::text AS variant, net_carry_usd_micros::numeric AS net_carry FROM opportunity_decisions ORDER BY variant, observed_at_ms DESC, id DESC), funding AS (SELECT portfolio_run_id, COALESCE(sum(usd_value_atoms::numeric), 0) AS amount FROM funding_payments GROUP BY portfolio_run_id), valuation AS (SELECT portfolio_run_id, COALESCE(sum(reward_accrual_usd_atoms::numeric), 0) AS reward, COALESCE(sum(basis_change_usd_atoms::numeric), 0) AS basis FROM valuation_events GROUP BY portfolio_run_id), fees AS (SELECT lb.portfolio_run_id, COALESCE(sum(le.usd_value_atoms::numeric) FILTER (WHERE lb.event_type LIKE '%spot_fill'), 0) AS spot, COALESCE(sum(le.usd_value_atoms::numeric) FILTER (WHERE lb.event_type LIKE '%perp_fill'), 0) AS perp FROM ledger_entries le JOIN ledger_batches lb ON lb.id = le.ledger_batch_id WHERE le.account_debit = 'trading_fees' GROUP BY lb.portfolio_run_id), pnl AS (SELECT p.id, COALESCE(f.amount, 0) AS funding, COALESCE(v.reward, 0) AS reward, COALESCE(v.basis, 0) AS basis, COALESCE(fe.spot, 0) AS spot_fees, COALESCE(fe.perp, 0) AS perp_fees FROM portfolio_base p LEFT JOIN funding f ON f.portfolio_run_id = p.id LEFT JOIN valuation v ON v.portfolio_run_id = p.id LEFT JOIN fees fe ON fe.portfolio_run_id = p.id), comparison AS (SELECT g.mode::text AS mode, COALESCE(max((pn.funding + pn.reward + pn.basis - pn.spot_fees - pn.perp_fees)) FILTER (WHERE p.variant = 'jitosol_carry'), 0) - COALESCE(max((pn.funding + pn.reward + pn.basis - pn.spot_fees - pn.perp_fees)) FILTER (WHERE p.variant = 'sol_control'), 0) AS incremental FROM comparison_groups g JOIN portfolio_runs p ON p.comparison_group_id = g.id JOIN pnl pn ON pn.id = p.id WHERE g.strategy_run_id = 'local-paper-run' GROUP BY g.mode), order_dimensions(leg, status) AS (VALUES ('SPOT', 'filled'), ('SPOT', 'partial'), ('SPOT', 'rejected'), ('PERP', 'filled'), ('PERP', 'partial'), ('PERP', 'rejected')), order_counts AS (SELECT ei.leg, o.status, count(*) AS count FROM orders o JOIN execution_intents ei ON ei.id = o.intent_id WHERE o.execution_mode = 'paper' AND ei.leg IN ('SPOT', 'PERP') AND o.status IN ('filled', 'partial', 'rejected') GROUP BY ei.leg, o.status), shadow_dimensions(status) AS (VALUES ('PLANNED'), ('UNKNOWN'), ('REJECTED')), shadow_counts AS (SELECT status, count(*) AS count FROM shadow_execution_results GROUP BY status), shadow_errors AS (SELECT DISTINCT ON (intent_json->>'leg') intent_json->>'leg' AS leg, CASE WHEN paper_price_atoms::numeric = 0 THEN 0 ELSE trunc(abs(price_error_atoms::numeric) * 10000 / paper_price_atoms::numeric) END AS error_bps FROM shadow_execution_results WHERE intent_json->>'leg' IN ('SPOT', 'PERP') ORDER BY intent_json->>'leg', updated_at DESC, command_id DESC), severities(severity) AS (VALUES ('info'), ('warning'), ('critical')), risk_counts AS (SELECT severity, count(*) AS count FROM risk_events GROUP BY severity), samples(sort, sample) AS (SELECT 10, 'market_data_age_seconds{source=\"adapter\",type=\"protocol_event\"} ' || (GREATEST($1::numeric - m.observed_at_ms, 0) / 1000)::text FROM market m UNION ALL SELECT 20, 'market_updates_total{source=\"adapter\",type=\"market_snapshot\"} ' || count(*)::text FROM normalized_events WHERE event_type = 'MarketSnapshot' UNION ALL SELECT 21, 'market_updates_total{source=\"adapter\",type=\"funding_settlement\"} ' || count(*)::text FROM normalized_events WHERE event_type = 'FundingSettlement' UNION ALL SELECT 30, 'adapter_to_mesh_latency_seconds_bucket{type=\"protocol_event\",le=\"0.005\"} ' || le_5::text FROM latency_stats UNION ALL SELECT 31, 'adapter_to_mesh_latency_seconds_bucket{type=\"protocol_event\",le=\"0.025\"} ' || le_25::text FROM latency_stats UNION ALL SELECT 32, 'adapter_to_mesh_latency_seconds_bucket{type=\"protocol_event\",le=\"0.1\"} ' || le_100::text FROM latency_stats UNION ALL SELECT 33, 'adapter_to_mesh_latency_seconds_bucket{type=\"protocol_event\",le=\"0.5\"} ' || le_500::text FROM latency_stats UNION ALL SELECT 34, 'adapter_to_mesh_latency_seconds_bucket{type=\"protocol_event\",le=\"+Inf\"} ' || count::text FROM latency_stats UNION ALL SELECT 35, 'adapter_to_mesh_latency_seconds_sum{type=\"protocol_event\"} ' || sum::text FROM latency_stats UNION ALL SELECT 36, 'adapter_to_mesh_latency_seconds_count{type=\"protocol_event\"} ' || count::text FROM latency_stats UNION ALL SELECT 40, 'adapter_connected{adapter=\"protocol-ts\"} ' || CASE WHEN m.observed_at_ms > 0 AND $1::numeric - m.observed_at_ms <= $2::numeric THEN '1' ELSE '0' END FROM market m UNION ALL SELECT 41, 'adapter_schema_compatible{adapter=\"protocol-ts\"} ' || CASE WHEN m.schema_version = 1 THEN '1' ELSE '0' END FROM market m UNION ALL SELECT 42, 'funding_rate_hourly{venue=\"paper\",market=\"SOL-PERP\",kind=\"expected\"} ' || COALESCE((m.payload->>'shortReceiptPpm')::numeric / 1000000, 0)::text FROM market m UNION ALL SELECT 43, 'spot_perp_basis_bps{portfolio=\"' || p.id || '\"} ' || CASE WHEN COALESCE((m.payload->>'solPriceUsdMicros')::numeric, 0) = 0 THEN '0' ELSE trunc(abs((((m.payload->>'perpBidPriceUsdMicros')::numeric + (m.payload->>'perpAskPriceUsdMicros')::numeric) / 2) - (m.payload->>'solPriceUsdMicros')::numeric) * 10000 / (m.payload->>'solPriceUsdMicros')::numeric)::text END FROM portfolio_base p CROSS JOIN market m UNION ALL SELECT 50, 'jitosol_protocol_nav_rate_lamports ' || CASE WHEN COALESCE((m.payload->>'supplyAtoms')::numeric, 0) = 0 THEN '0' ELSE trunc((m.payload->>'totalPoolLamports')::numeric * 1000000000 / (m.payload->>'supplyAtoms')::numeric)::text END FROM market m UNION ALL SELECT 51, 'jitosol_executable_buy_rate_lamports{size=\"paper\"} ' || CASE WHEN COALESCE((m.payload->>'solPriceUsdMicros')::numeric, 0) = 0 THEN '0' ELSE trunc((m.payload->>'jitosolSpotAskPriceUsdMicros')::numeric * 1000000000 / (m.payload->>'solPriceUsdMicros')::numeric)::text END FROM market m UNION ALL SELECT 52, 'jitosol_executable_sell_rate_lamports{size=\"paper\"} ' || CASE WHEN COALESCE((m.payload->>'solPriceUsdMicros')::numeric, 0) = 0 THEN '0' ELSE trunc((m.payload->>'jitosolSpotBidPriceUsdMicros')::numeric * 1000000000 / (m.payload->>'solPriceUsdMicros')::numeric)::text END FROM market m UNION ALL SELECT 53, 'jitosol_nav_market_deviation_bps{size=\"paper\"} ' || CASE WHEN COALESCE((m.payload->>'totalPoolLamports')::numeric, 0) = 0 OR COALESCE((m.payload->>'supplyAtoms')::numeric, 0) = 0 OR COALESCE((m.payload->>'solPriceUsdMicros')::numeric, 0) = 0 THEN '0' ELSE trunc(abs(((m.payload->>'totalPoolLamports')::numeric * 1000000000 / (m.payload->>'supplyAtoms')::numeric) - ((m.payload->>'jitosolSpotBidPriceUsdMicros')::numeric * 1000000000 / (m.payload->>'solPriceUsdMicros')::numeric)) * 10000 / ((m.payload->>'totalPoolLamports')::numeric * 1000000000 / (m.payload->>'supplyAtoms')::numeric))::text END FROM market m UNION ALL SELECT 54, 'jitosol_exit_depth_usd_micros ' || trunc(COALESCE((m.payload->>'jitosolExitDepthLamports')::numeric, 0) * COALESCE((m.payload->>'solPriceUsdMicros')::numeric, 0) / 1000000000)::text FROM market m UNION ALL SELECT 55, 'jitosol_epoch ' || COALESCE(m.payload->>'epoch', '0') FROM market m UNION ALL SELECT 60, 'strategy_state{portfolio=\"' || p.id || '\",state=\"' || p.state || '\"} 1' FROM portfolio_base p UNION ALL SELECT 61, 'opportunity_expected_net_usd_micros{portfolio=\"' || p.id || '\"} ' || COALESCE(d.net_carry, 0)::text FROM portfolio_base p LEFT JOIN latest_decisions d ON d.variant = p.variant UNION ALL SELECT 62, 'position_spot_equivalent_sol_atoms{portfolio=\"' || p.id || '\"} ' || p.spot_equivalent::text FROM positions p UNION ALL SELECT 63, 'position_perp_sol_atoms{portfolio=\"' || p.id || '\"} ' || p.perp_short::text FROM positions p UNION ALL SELECT 64, 'position_net_delta_sol_atoms{portfolio=\"' || p.id || '\"} ' || (p.spot_equivalent - p.perp_short)::text FROM positions p UNION ALL SELECT 65, 'position_delta_bps{portfolio=\"' || p.id || '\"} ' || CASE WHEN p.spot_equivalent = 0 THEN '0' ELSE ceil(abs(p.spot_equivalent - p.perp_short) * 10000 / p.spot_equivalent)::text END FROM positions p UNION ALL SELECT 66, 'position_gross_notional_usd_micros{portfolio=\"' || p.id || '\"} ' || trunc((abs(p.spot_equivalent) + abs(p.perp_short)) * p.sol_price / 1000000000)::text FROM positions p UNION ALL SELECT 67, 'comparison_incremental_jitosol_pnl_usd_micros{mode=\"' || c.mode || '\"} ' || c.incremental::text FROM comparison c UNION ALL SELECT 70, 'orders_total{mode=\"paper\",venue=\"paper\",leg=\"' || lower(d.leg) || '\",status=\"' || d.status || '\"} ' || COALESCE(c.count, 0)::text FROM order_dimensions d LEFT JOIN order_counts c ON c.leg = d.leg AND c.status = d.status UNION ALL SELECT 71, 'partial_fills_total{venue=\"paper\",leg=\"' || lower(d.leg) || '\"} ' || COALESCE(c.count, 0)::text FROM (VALUES ('SPOT'), ('PERP')) d(leg) LEFT JOIN order_counts c ON c.leg = d.leg AND c.status = 'partial' UNION ALL SELECT 72, 'shadow_paper_fill_error_bps{leg=\"' || lower(d.leg) || '\"} ' || COALESCE(e.error_bps, 0)::text FROM (VALUES ('SPOT'), ('PERP')) d(leg) LEFT JOIN shadow_errors e ON e.leg = d.leg UNION ALL SELECT 73, 'shadow_executor_results{status=\"' || lower(d.status) || '\"} ' || COALESCE(c.count, 0)::text FROM shadow_dimensions d LEFT JOIN shadow_counts c ON c.status = d.status UNION ALL SELECT 74, 'executor_policy_rejections_total{reason=\"policy\"} ' || count(*)::text FROM shadow_execution_results WHERE status = 'REJECTED' UNION ALL SELECT 80, 'margin_ratio_ppm ' || CASE WHEN COALESCE((m.payload->>'maintenanceRequirementUsdMicros')::numeric, 0) = 0 THEN '0' ELSE trunc((m.payload->>'collateralUsdMicros')::numeric * 1000000 / (m.payload->>'maintenanceRequirementUsdMicros')::numeric)::text END FROM market m UNION ALL SELECT 81, 'liquidation_distance_bps ' || COALESCE(m.payload->>'liquidationDistanceBps', '0') FROM market m UNION ALL SELECT 82, 'risk_events_total{severity=\"' || s.severity || '\"} ' || COALESCE(r.count, 0)::text FROM severities s LEFT JOIN risk_counts r ON r.severity = s.severity UNION ALL SELECT 83, 'reconciliation_mismatches_total{type=\"paper\"} ' || count(*)::text FROM reconciliations WHERE result <> 'matched' UNION ALL SELECT 84, 'funding_received_usd_micros{portfolio=\"' || p.id || '\"} ' || p.funding::text FROM pnl p UNION ALL SELECT 85, 'jitosol_reward_accrual_usd_micros{portfolio=\"' || p.id || '\"} ' || p.reward::text FROM pnl p JOIN portfolio_base b ON b.id = p.id WHERE b.variant = 'jitosol_carry' UNION ALL SELECT 86, 'jitosol_basis_pnl_usd_micros{portfolio=\"' || p.id || '\"} ' || p.basis::text FROM pnl p JOIN portfolio_base b ON b.id = p.id WHERE b.variant = 'jitosol_carry' UNION ALL SELECT 87, 'spot_fees_usd_micros_total{portfolio=\"' || p.id || '\"} ' || p.spot_fees::text FROM pnl p UNION ALL SELECT 88, 'perp_fees_usd_micros_total{portfolio=\"' || p.id || '\"} ' || p.perp_fees::text FROM pnl p UNION ALL SELECT 89, 'net_pnl_usd_micros{portfolio=\"' || p.id || '\"} ' || (p.funding + p.reward + p.basis - p.spot_fees - p.perp_fees)::text FROM pnl p UNION ALL SELECT 90, 'leader_lease_held ' || CASE WHEN EXISTS (SELECT 1 FROM leader_leases WHERE lease_name = 'collector' AND holder_instance_id = $3 AND expires_at > clock_timestamp()) THEN '1' ELSE '0' END UNION ALL SELECT 91, 'mesh_outbox_pending ' || count(*)::text FROM outbox_commands WHERE processed_at IS NULL) SELECT COALESCE(string_agg(sample, E'\\n' ORDER BY sort, sample), '') || E'\\n' AS body FROM samples"
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
      <> (Env.get("MESH_COMMIT", "development")
        |> escape_label_value
        |2> build_metric(
          Env.get("CODE_COMMIT", "development") |> escape_label_value
        ))
      <> (Cluster.telemetry() |> runtime_metrics)
      <> ((now_ms |2> database_metrics(pool, max_age_ms)) ?)
  )
end
