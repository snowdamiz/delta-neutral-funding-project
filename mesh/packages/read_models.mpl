fn read_body(pool :: PoolHandle, query :: String, arguments) -> String ! String do
  let rows = Pool.query(pool, query, arguments) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid read model")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end

# The strategy catalog. This list is the collector's registry of what exists:
# the console renders whatever it returns and hardcodes nothing, so a new
# strategy is one row here plus its own data, never a UI change. legs,
# benchmarkStrategyId and controlScope are declarations about the strategy;
# runState and portfolioRunIds are joined from the paper runs it owns, so an
# entry with no runs yet reports 'unregistered' rather than looking broken.
# controlScope is 'global' while the collector's pause state is a singleton —
# the console must not offer a per-strategy stop the collector cannot honour.
pub fn strategies(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH catalog(ordinal, id, display_name, family, legs, benchmark_id, mode, control_scope) AS (VALUES (1, 'sol_control', 'SOL control', 'carry', jsonb_build_array('long SOL spot', 'short SOL-PERP'), '', 'paper', 'global'), (2, 'jitosol_carry', 'JitoSOL carry', 'carry', jsonb_build_array('long JitoSOL spot', 'short SOL-PERP at protocol NAV'), 'sol_control', 'paper', 'global'), (3, 'cross_asset_funding', 'Cross-asset funding', 'carry', jsonb_build_array('long top-ranked spot asset', 'short matching perpetual'), 'sol_control', 'paper', 'global'), (4, 'negative_funding_reverse', 'Negative-funding reverse carry', 'carry', jsonb_build_array('borrow and sell ranked spot asset', 'long matching perpetual'), 'sol_control', 'paper', 'global'), (5, 'jitosol_nav_discount', 'JitoSOL NAV discount', 'arbitrage', jsonb_build_array('buy JitoSOL below protocol NAV', 'short NAV-equivalent SOL-PERP', 'redeem through the best modeled exit'), 'sol_control', 'paper', 'global'), (6, 'cross_venue_funding', 'Cross-venue funding arbitrage', 'arbitrage', jsonb_build_array('short the high-funding perpetual', 'long the low-funding perpetual'), 'sol_control', 'paper', 'global'), (7, 'hyperliquid_wallet_flow', 'Hyperliquid wallet flow', 'signal', jsonb_build_array('aggregate qualified wallet direction', 'filter Phase 1-4 entries'), 'cross_asset_funding', 'paper', 'global'), (8, 'hyperliquid_wallet_mirror', 'Hyperliquid wallet mirror', 'signal', jsonb_build_array('mirror qualified wallet direction', 'size from local risk limits'), 'cross_asset_funding', 'paper', 'global'), (9, 'hyperliquid_wallet_fade', 'Hyperliquid wallet fade', 'signal', jsonb_build_array('fade consistently losing wallets', 'size from local risk limits'), 'cross_asset_funding', 'paper', 'global')), runs AS (SELECT variant::text AS id, jsonb_agg(id ORDER BY comparison_group_id, id) AS portfolio_run_ids, count(*) FILTER (WHERE state NOT IN ('idle', 'paused')) AS working, count(*) FILTER (WHERE state = 'paused') AS paused, count(*) AS total FROM portfolio_runs WHERE strategy_run_id = 'local-paper-run' GROUP BY variant), items AS (SELECT jsonb_build_object('id', c.id, 'displayName', c.display_name, 'family', c.family, 'legs', c.legs, 'benchmarkStrategyId', NULLIF(c.benchmark_id, ''), 'mode', c.mode, 'controlScope', c.control_scope, 'runState', CASE WHEN r.total IS NULL THEN 'unregistered' WHEN r.working > 0 THEN 'active' WHEN r.paused = r.total THEN 'paused' ELSE 'idle' END, 'portfolioRunIds', COALESCE(r.portfolio_run_ids, '[]'::jsonb)) AS item FROM catalog c LEFT JOIN runs r ON r.id = c.id ORDER BY c.ordinal) SELECT jsonb_build_object('schemaVersion', 1, 'strategies', COALESCE(jsonb_agg(item), '[]'::jsonb))::text AS body FROM items", [])
end

pub fn portfolios(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH items AS (SELECT jsonb_build_object('id', p.id, 'strategyRunId', p.strategy_run_id, 'comparisonGroupId', p.comparison_group_id, 'comparisonMode', g.mode::text, 'variant', p.variant::text, 'executionMode', p.execution_mode::text, 'state', p.state::text, 'stateVersion', p.state_version::text, 'randomState', p.random_state::text, 'initialCapitalUsd', jsonb_build_object('atoms', p.initial_capital_usd_micros::text, 'scale', 6), 'startedAt', p.started_at, 'endedAt', p.ended_at) AS item FROM portfolio_runs p LEFT JOIN comparison_groups g ON g.id = p.comparison_group_id WHERE p.strategy_run_id = 'local-paper-run' ORDER BY g.mode, p.variant) SELECT COALESCE(jsonb_agg(item), '[]'::jsonb)::text AS body FROM items", [])
end

pub fn portfolio(pool :: PoolHandle, portfolio_id :: String) -> String ! String do
  read_body(pool, "SELECT COALESCE((SELECT jsonb_build_object('id', p.id, 'strategyRunId', p.strategy_run_id, 'comparisonGroupId', p.comparison_group_id, 'comparisonMode', g.mode::text, 'variant', p.variant::text, 'executionMode', p.execution_mode::text, 'state', p.state::text, 'stateVersion', p.state_version::text, 'randomState', p.random_state::text, 'initialCapitalUsd', jsonb_build_object('atoms', p.initial_capital_usd_micros::text, 'scale', 6), 'startedAt', p.started_at, 'endedAt', p.ended_at) FROM portfolio_runs p LEFT JOIN comparison_groups g ON g.id = p.comparison_group_id WHERE p.id = $1), 'null'::jsonb)::text AS body", [portfolio_id])
end

pub fn positions(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH balances AS (SELECT p.id, p.variant, p.state, COALESCE(sum(CASE WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'BUY' THEN f.quantity_atoms::numeric WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'SELL' THEN -f.quantity_atoms::numeric ELSE 0 END), 0) AS spot_quantity, COALESCE(sum(CASE WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'SELL' THEN f.quantity_atoms::numeric WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'BUY' THEN -f.quantity_atoms::numeric ELSE 0 END), 0) AS perp_short FROM portfolio_runs p LEFT JOIN fills f ON f.portfolio_run_id = p.id LEFT JOIN orders o ON o.id = f.order_id LEFT JOIN execution_intents ei ON ei.id = o.intent_id WHERE p.strategy_run_id = 'local-paper-run' AND p.variant NOT IN ('cross_asset_funding', 'negative_funding_reverse', 'jitosol_nav_discount', 'cross_venue_funding', 'hyperliquid_wallet_flow', 'hyperliquid_wallet_mirror', 'hyperliquid_wallet_fade') GROUP BY p.id, p.variant, p.state), latest_market AS (SELECT id AS source_event_id, (canonical_payload#>>'{payload,jitosolSpotBidPriceUsdMicros}')::numeric / (canonical_payload#>>'{payload,solPriceUsdMicros}')::numeric AS jito_rate, (canonical_payload#>>'{payload,collateralUsdMicros}')::numeric AS collateral, (canonical_payload#>>'{payload,maintenanceRequirementUsdMicros}')::numeric AS maintenance, (canonical_payload#>>'{payload,liquidationDistanceBps}')::numeric AS liquidation_distance FROM normalized_events WHERE event_type = 'MarketSnapshot' ORDER BY observed_at_ms DESC LIMIT 1), valued AS (SELECT b.*, lm.*, trunc(b.spot_quantity * CASE WHEN b.variant = 'sol_control' THEN 1 ELSE COALESCE(lm.jito_rate, 0) END) AS spot_equivalent FROM balances b LEFT JOIN latest_market lm ON true), items AS (SELECT variant::text AS variant, jsonb_build_object('portfolioRunId', id, 'variant', variant::text, 'state', state::text, 'asset', CASE WHEN variant = 'sol_control' THEN 'SOL' ELSE 'JitoSOL' END, 'spotQuantity', jsonb_build_object('atoms', spot_quantity::text, 'scale', 9), 'spotEquivalentSol', jsonb_build_object('atoms', spot_equivalent::text, 'scale', 9), 'perpShortSol', jsonb_build_object('atoms', perp_short::text, 'scale', 9), 'netDeltaSol', jsonb_build_object('atoms', (spot_equivalent - perp_short)::text, 'scale', 9), 'deltaBps', CASE WHEN spot_equivalent = 0 THEN '0' ELSE ceil(abs(spot_equivalent - perp_short) * 10000 / spot_equivalent)::text END, 'marginSnapshot', CASE WHEN maintenance IS NULL THEN 'null'::jsonb ELSE jsonb_build_object('sourceEventId', source_event_id, 'collateralUsd', jsonb_build_object('atoms', collateral::text, 'scale', 6), 'maintenanceRequirementUsd', jsonb_build_object('atoms', maintenance::text, 'scale', 6), 'marginRatioPpm', trunc(collateral * 1000000 / maintenance)::text, 'liquidationDistanceBps', liquidation_distance::text) END) AS item FROM valued), cross_items AS (SELECT p.variant::text AS variant, jsonb_build_object('portfolioRunId', p.id, 'variant', p.variant::text, 'state', p.state::text, 'asset', COALESCE(x.asset, ''), 'spotQuantity', jsonb_build_object('atoms', COALESCE(x.quantity_atoms, 0)::text, 'scale', 9), 'spotEquivalentSol', jsonb_build_object('atoms', COALESCE(x.quantity_atoms, 0)::text, 'scale', 9), 'perpShortSol', jsonb_build_object('atoms', COALESCE(x.quantity_atoms, 0)::text, 'scale', 9), 'netDeltaSol', jsonb_build_object('atoms', '0', 'scale', 9), 'deltaBps', '0', 'marginSnapshot', 'null'::jsonb) AS item FROM portfolio_runs p LEFT JOIN cross_asset_paper_positions x ON x.portfolio_run_id = p.id AND x.status IN ('open', 'exit_blocked') WHERE p.strategy_run_id = 'local-paper-run' AND p.variant = 'cross_asset_funding'), reverse_items AS (SELECT p.variant::text AS variant, jsonb_build_object('portfolioRunId', p.id, 'variant', p.variant::text, 'state', p.state::text, 'asset', COALESCE(x.asset, ''), 'spotQuantity', jsonb_build_object('atoms', (-COALESCE(x.quantity_atoms, 0))::text, 'scale', 9), 'spotEquivalentSol', jsonb_build_object('atoms', (-COALESCE(x.quantity_atoms, 0))::text, 'scale', 9), 'perpShortSol', jsonb_build_object('atoms', (-COALESCE(x.quantity_atoms, 0))::text, 'scale', 9), 'netDeltaSol', jsonb_build_object('atoms', '0', 'scale', 9), 'deltaBps', '0', 'marginSnapshot', 'null'::jsonb) AS item FROM portfolio_runs p LEFT JOIN reverse_carry_paper_positions x ON x.portfolio_run_id = p.id AND x.status IN ('open', 'exit_blocked') WHERE p.strategy_run_id = 'local-paper-run' AND p.variant = 'negative_funding_reverse'), nav_items AS (SELECT p.variant::text AS variant, jsonb_build_object('portfolioRunId', p.id, 'variant', p.variant::text, 'state', p.state::text, 'asset', 'JitoSOL', 'spotQuantity', jsonb_build_object('atoms', COALESCE(x.quantity_atoms, 0)::text, 'scale', 9), 'spotEquivalentSol', jsonb_build_object('atoms', COALESCE(x.hedge_quantity_atoms, 0)::text, 'scale', 9), 'perpShortSol', jsonb_build_object('atoms', COALESCE(x.hedge_quantity_atoms, 0)::text, 'scale', 9), 'netDeltaSol', jsonb_build_object('atoms', '0', 'scale', 9), 'deltaBps', '0', 'marginSnapshot', 'null'::jsonb) AS item FROM portfolio_runs p LEFT JOIN nav_discount_paper_positions x ON x.portfolio_run_id = p.id AND x.status IN ('open', 'exit_blocked') WHERE p.strategy_run_id = 'local-paper-run' AND p.variant = 'jitosol_nav_discount'), venue_items AS (SELECT p.variant::text AS variant, jsonb_build_object('portfolioRunId', p.id, 'variant', p.variant::text, 'state', p.state::text, 'asset', COALESCE(x.asset, ''), 'spotQuantity', jsonb_build_object('atoms', '0', 'scale', 9), 'spotEquivalentSol', jsonb_build_object('atoms', '0', 'scale', 9), 'perpShortSol', jsonb_build_object('atoms', '0', 'scale', 9), 'netDeltaSol', jsonb_build_object('atoms', '0', 'scale', 9), 'deltaBps', '0', 'marginSnapshot', CASE WHEN x.id IS NULL THEN 'null'::jsonb ELSE jsonb_build_object('sourceEventId', x.latest_short_source_event_id, 'collateralUsd', jsonb_build_object('atoms', CASE WHEN x.short_margin_ratio_ppm <= x.long_margin_ratio_ppm THEN x.short_collateral_usd_micros ELSE x.long_collateral_usd_micros END::text, 'scale', 6), 'maintenanceRequirementUsd', jsonb_build_object('atoms', CASE WHEN x.short_margin_ratio_ppm <= x.long_margin_ratio_ppm THEN x.short_maintenance_usd_micros ELSE x.long_maintenance_usd_micros END::text, 'scale', 6), 'marginRatioPpm', LEAST(x.short_margin_ratio_ppm, x.long_margin_ratio_ppm)::text, 'liquidationDistanceBps', LEAST(x.short_liquidation_distance_bps, x.long_liquidation_distance_bps)::text) END) AS item FROM portfolio_runs p LEFT JOIN cross_venue_paper_positions x ON x.portfolio_run_id = p.id AND x.status IN ('open', 'exit_blocked') WHERE p.strategy_run_id = 'local-paper-run' AND p.variant = 'cross_venue_funding'), all_items AS (SELECT * FROM items UNION ALL SELECT * FROM cross_items UNION ALL SELECT * FROM reverse_items UNION ALL SELECT * FROM nav_items UNION ALL SELECT * FROM venue_items) SELECT COALESCE(jsonb_agg(item ORDER BY variant), '[]'::jsonb)::text AS body FROM all_items", [])
end

pub fn orders(pool :: PoolHandle, limit :: Int, offset :: Int) -> String ! String do
  read_body(pool, "WITH items AS (SELECT jsonb_build_object('id', o.id, 'intentId', o.intent_id, 'intent', ei.intent_json, 'intentHash', ei.intent_hash, 'portfolioRunId', o.portfolio_run_id, 'executionMode', o.execution_mode::text, 'variant', o.variant::text, 'status', o.status, 'requestedQuantity', jsonb_build_object('atoms', o.requested_quantity_atoms, 'scale', 9), 'filledQuantity', jsonb_build_object('atoms', o.filled_quantity_atoms, 'scale', 9), 'externalId', o.external_id, 'createdAt', o.created_at, 'updatedAt', o.updated_at) AS item FROM orders o JOIN execution_intents ei ON ei.id = o.intent_id ORDER BY o.created_at DESC, o.id DESC LIMIT $1::int OFFSET $2::int) SELECT jsonb_build_object('items', COALESCE(jsonb_agg(item), '[]'::jsonb), 'limit', $1::int, 'offset', $2::int)::text AS body FROM items", ["${limit}", "${offset}"])
end

pub fn shadow_results(
  pool :: PoolHandle,
  limit :: Int,
  offset :: Int
) -> String ! String do
  read_body(pool, "WITH items AS (SELECT jsonb_build_object('commandId', command_id, 'intentHash', intent_hash, 'messageHash', message_hash, 'market', market, 'status', status, 'retryAllowed', status <> 'UNKNOWN', 'paperEstimate', paper_estimate_json, 'simulation', jsonb_build_object('quantityAtoms', simulated_quantity_atoms, 'averagePriceAtoms', simulated_price_atoms, 'feeAtoms', simulated_fee_atoms), 'errorAtoms', jsonb_build_object('quantity', quantity_error_atoms, 'averagePrice', price_error_atoms, 'fee', fee_error_atoms), 'action', action_json, 'report', report_json, 'reconciliationCount', reconciliation_count, 'createdAt', created_at, 'updatedAt', updated_at) AS item FROM shadow_execution_results ORDER BY updated_at DESC, command_id LIMIT $1::int OFFSET $2::int) SELECT COALESCE(jsonb_agg(item), '[]'::jsonb)::text AS body FROM items", ["${limit}", "${offset}"])
end

pub fn fills(pool :: PoolHandle, limit :: Int, offset :: Int) -> String ! String do
  read_body(pool, "WITH items AS (SELECT jsonb_build_object('id', id, 'orderId', order_id, 'portfolioRunId', portfolio_run_id, 'executionMode', execution_mode::text, 'variant', variant::text, 'quantity', jsonb_build_object('atoms', quantity_atoms, 'scale', 9), 'priceUsd', jsonb_build_object('atoms', price_atoms, 'scale', 6), 'feeUsd', jsonb_build_object('atoms', fee_atoms, 'scale', 6), 'sourceSnapshotId', source_snapshot_id, 'explanation', explanation, 'createdAt', created_at) AS item FROM fills ORDER BY created_at DESC, id DESC LIMIT $1::int OFFSET $2::int) SELECT jsonb_build_object('items', COALESCE(jsonb_agg(item), '[]'::jsonb), 'limit', $1::int, 'offset', $2::int)::text AS body FROM items", ["${limit}", "${offset}"])
end

pub fn funding(pool :: PoolHandle, limit :: Int, offset :: Int) -> String ! String do
  read_body(pool, "WITH items AS (SELECT jsonb_build_object('id', id, 'portfolioRunId', portfolio_run_id, 'venuePaymentId', venue_payment_id, 'effectiveAtMs', effective_at_ms::text, 'positionQuantity', jsonb_build_object('atoms', position_quantity_atoms, 'scale', 9), 'rawRate', jsonb_build_object('atoms', raw_rate_atoms, 'scale', 6), 'normalizedRate', jsonb_build_object('atoms', normalized_rate_atoms, 'scale', 6), 'amountUsd', jsonb_build_object('atoms', usd_value_atoms, 'scale', 6), 'realizationStatus', realization_status, 'sourceEventId', source_event_id) AS item FROM funding_payments ORDER BY effective_at_ms DESC, id DESC LIMIT $1::int OFFSET $2::int) SELECT jsonb_build_object('items', COALESCE(jsonb_agg(item), '[]'::jsonb), 'limit', $1::int, 'offset', $2::int)::text AS body FROM items", ["${limit}", "${offset}"])
end

pub fn funding_leaderboard(
  pool :: PoolHandle,
  now_ms :: Int,
  source_max_age_ms :: Int,
  notional_usd_micros :: Int,
  costs_usd_micros :: Int,
  risk_usd_micros :: Int,
  hold_hours :: Int
) -> String ! String do
  read_body(
    pool,
    "SELECT funding_leaderboard($1::bigint, $2::bigint, $3::bigint, $4::bigint, $5::bigint, $6::int)::text AS body",
    [
      "${now_ms}",
      "${source_max_age_ms}",
      "${notional_usd_micros}",
      "${costs_usd_micros}",
      "${risk_usd_micros}",
      "${hold_hours}"
    ]
  )
end

pub fn reverse_carry_leaderboard(
  pool :: PoolHandle,
  now_ms :: Int,
  funding_source_max_age_ms :: Int,
  borrow_source_max_age_ms :: Int,
  notional_usd_micros :: Int,
  costs_usd_micros :: Int,
  risk_usd_micros :: Int,
  hold_hours :: Int,
  maximum_break_even_hours :: Int,
  minimum_negative_funding_ppm :: Int,
  maximum_borrow_utilization_ppm :: Int
) -> String ! String do
  read_body(
    pool,
    "SELECT reverse_carry_leaderboard($1::bigint, $2::bigint, $3::bigint, $4::bigint, $5::bigint, $6::bigint, $7::int, $8::int, $9::bigint, $10::bigint)::text AS body",
    [
      "${now_ms}",
      "${funding_source_max_age_ms}",
      "${borrow_source_max_age_ms}",
      "${notional_usd_micros}",
      "${costs_usd_micros}",
      "${risk_usd_micros}",
      "${hold_hours}",
      "${maximum_break_even_hours}",
      "${minimum_negative_funding_ppm}",
      "${maximum_borrow_utilization_ppm}"
    ]
  )
end

pub fn cross_venue_funding_leaderboard(
  pool :: PoolHandle,
  now_ms :: Int,
  source_max_age_ms :: Int,
  notional_usd_micros :: Int,
  costs_usd_micros :: Int,
  risk_usd_micros :: Int,
  hold_hours :: Int,
  collateral_usd_micros :: Int,
  minimum_margin_ratio_ppm :: Int,
  minimum_liquidation_distance_bps :: Int
) -> String ! String do
  read_body(
    pool,
    "SELECT cross_venue_funding_leaderboard($1::bigint, $2::bigint, $3::bigint, $4::bigint, $5::bigint, $6::int, $7::bigint, $8::bigint, $9::bigint)::text AS body",
    [
      "${now_ms}",
      "${source_max_age_ms}",
      "${notional_usd_micros}",
      "${costs_usd_micros}",
      "${risk_usd_micros}",
      "${hold_hours}",
      "${collateral_usd_micros}",
      "${minimum_margin_ratio_ppm}",
      "${minimum_liquidation_distance_bps}"
    ]
  )
end

pub fn wallet_tracking(pool :: PoolHandle, now_ms :: Int) -> String ! String do
  read_body(
    pool,
    "WITH config AS (SELECT jsonb_build_object('version', s.version::text, 'wallets', COALESCE(jsonb_agg(w.wallet ORDER BY w.ordinal) FILTER (WHERE w.wallet IS NOT NULL), '[]'::jsonb), 'maximumWallets', '50', 'updatedAt', s.updated_at) AS value FROM wallet_tracking_config_state s LEFT JOIN wallet_tracking_wallets w ON true GROUP BY s.version, s.updated_at), signals AS (SELECT jsonb_build_object('asset', asset, 'observedAtMs', observed_at_ms::text, 'signalPpm', signal_ppm::text, 'qualifiedWallets', qualified_wallets::text, 'qualified', qualified) AS item FROM wallet_flow_signals WHERE (asset, observed_at_ms) IN (SELECT asset, max(observed_at_ms) FROM wallet_flow_signals GROUP BY asset) ORDER BY asset), positions AS (SELECT jsonb_build_object('portfolioRunId', portfolio_run_id, 'mode', mode, 'wallet', wallet, 'asset', asset, 'side', side, 'status', status, 'quantityAtoms', quantity_atoms::text, 'entryPriceUsdMicros', entry_price_usd_micros::text, 'exitPriceUsdMicros', COALESCE(exit_price_usd_micros, 0)::text, 'realizedNetUsdMicros', realized_net_usd_micros::text, 'openedAtMs', opened_at_ms::text, 'closedAtMs', COALESCE(closed_at_ms, 0)::text) AS item FROM wallet_paper_positions ORDER BY opened_at_ms DESC, id DESC LIMIT 100), decisions AS (SELECT jsonb_build_object('portfolioRunId', portfolio_run_id, 'fillId', fill_id, 'mode', mode, 'wallet', wallet, 'asset', asset, 'scoreAsOfMs', score_as_of_ms::text, 'scorePpm', score_ppm::text, 'closedDecisions', closed_decisions::text, 'signalPpm', signal_ppm::text, 'copyLatencyMs', copy_latency_ms::text, 'slippageUsdMicros', slippage_usd_micros::text, 'eligible', eligible, 'action', action, 'reasonCode', reason_code) AS item FROM wallet_paper_decisions ORDER BY created_at DESC, id DESC LIMIT 100) SELECT jsonb_build_object('config', (SELECT value FROM config), 'scores', wallet_consistency_scores($1::bigint, 20), 'signals', COALESCE((SELECT jsonb_agg(item) FROM signals), '[]'::jsonb), 'positions', COALESCE((SELECT jsonb_agg(item) FROM positions), '[]'::jsonb), 'decisions', COALESCE((SELECT jsonb_agg(item) FROM decisions), '[]'::jsonb), 'assessment', wallet_mode_assessment($1::bigint))::text AS body",
    ["${now_ms}"]
  )
end

pub fn wallet_config(pool :: PoolHandle) -> String ! String do
  read_body(
    pool,
    "SELECT jsonb_build_object('version', s.version::text, 'wallets', COALESCE(jsonb_agg(w.wallet ORDER BY w.ordinal) FILTER (WHERE w.wallet IS NOT NULL), '[]'::jsonb), 'maximumWallets', '50', 'updatedAt', s.updated_at)::text AS body FROM wallet_tracking_config_state s LEFT JOIN wallet_tracking_wallets w ON true GROUP BY s.version, s.updated_at",
    []
  )
end

pub fn jitosol(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH latest AS (SELECT jsonb_build_object('sourceEventId', source_event_id, 'quantity', jsonb_build_object('atoms', quantity_atoms, 'scale', 9), 'protocolNavRate', jsonb_build_object('atoms', protocol_nav_rate_atoms, 'scale', 9), 'marketSellRate', jsonb_build_object('atoms', market_sell_rate_atoms, 'scale', 9), 'rewardAccrualSol', jsonb_build_object('atoms', reward_accrual_sol_atoms, 'scale', 9), 'basisChangeSol', jsonb_build_object('atoms', basis_change_sol_atoms, 'scale', 9), 'rewardAccrualUsd', jsonb_build_object('atoms', reward_accrual_usd_atoms, 'scale', 6), 'basisChangeUsd', jsonb_build_object('atoms', basis_change_usd_atoms, 'scale', 6), 'createdAt', created_at) AS value FROM valuation_events WHERE portfolio_run_id = 'local-jitosol-carry' ORDER BY created_at DESC LIMIT 1), totals AS (SELECT COALESCE(sum(reward_accrual_usd_atoms::numeric), 0)::text AS reward, COALESCE(sum(basis_change_usd_atoms::numeric), 0)::text AS basis FROM valuation_events WHERE portfolio_run_id = 'local-jitosol-carry'), counterfactuals AS (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'portfolioRunId', portfolio_run_id, 'sourceEventId', source_event_id, 'state', state, 'requestedEpoch', requested_epoch::text, 'availableEpoch', available_epoch::text, 'jitosolQuantity', jsonb_build_object('atoms', jitosol_quantity_atoms, 'scale', 9), 'hedgeQuantity', jsonb_build_object('atoms', hedge_quantity_atoms, 'scale', 9), 'protocolRedemptionSol', jsonb_build_object('atoms', protocol_redemption_lamports, 'scale', 9), 'withdrawalFeeSol', jsonb_build_object('atoms', withdrawal_fee_lamports, 'scale', 9), 'cooldownFundingUsd', jsonb_build_object('atoms', cooldown_funding_usd_micros, 'scale', 6), 'netUsd', jsonb_build_object('atoms', net_usd_micros, 'scale', 6), 'updatedAt', updated_at) ORDER BY created_at DESC), '[]'::jsonb) AS value FROM direct_unstake_counterfactuals) SELECT jsonb_build_object('portfolioRunId', 'local-jitosol-carry', 'latest', COALESCE((SELECT value FROM latest), 'null'::jsonb), 'rewardAccrualUsdTotal', jsonb_build_object('atoms', totals.reward, 'scale', 6), 'basisPnlUsdTotal', jsonb_build_object('atoms', totals.basis, 'scale', 6), 'directUnstakeCounterfactuals', counterfactuals.value)::text AS body FROM totals CROSS JOIN counterfactuals", [])
end

pub fn pnl(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH funding AS (SELECT portfolio_run_id, COALESCE(sum(usd_value_atoms::numeric), 0) AS amount FROM funding_payments GROUP BY portfolio_run_id), valuation AS (SELECT v.portfolio_run_id, COALESCE(sum(v.reward_accrual_usd_atoms::numeric), 0) AS reward, COALESCE(sum(v.basis_change_usd_atoms::numeric), 0) AS basis FROM valuation_events v JOIN portfolio_runs p ON p.id = v.portfolio_run_id WHERE p.variant = 'jitosol_carry' GROUP BY v.portfolio_run_id), cross_basis AS (SELECT portfolio_run_id, COALESCE(sum(realized_basis_usd_micros), 0) AS basis FROM cross_asset_paper_positions GROUP BY portfolio_run_id), reverse_basis AS (SELECT portfolio_run_id, COALESCE(sum(realized_basis_usd_micros), 0) AS basis FROM reverse_carry_paper_positions GROUP BY portfolio_run_id), venue_basis AS (SELECT portfolio_run_id, COALESCE(sum(realized_basis_usd_micros), 0) AS basis FROM cross_venue_paper_positions GROUP BY portfolio_run_id), wallet_results AS (SELECT portfolio_run_id, COALESCE(sum(realized_net_usd_micros), 0) AS basis FROM wallet_paper_positions WHERE status = 'closed' GROUP BY portfolio_run_id), nav_results AS (SELECT portfolio_run_id, COALESCE(sum(realized_basis_usd_micros), 0) AS basis, COALESCE(sum(realized_funding_usd_micros), 0) AS funding FROM nav_discount_paper_positions GROUP BY portfolio_run_id), ledger_costs AS (SELECT lb.portfolio_run_id, COALESCE(sum(le.usd_value_atoms::numeric) FILTER (WHERE le.account_debit = 'trading_fees'), 0) AS fees, COALESCE(sum(le.usd_value_atoms::numeric) FILTER (WHERE le.account_debit = 'borrow_interest_expense'), 0) AS borrow FROM ledger_entries le JOIN ledger_batches lb ON lb.id = le.ledger_batch_id GROUP BY lb.portfolio_run_id), items AS (SELECT jsonb_build_object('portfolioRunId', p.id, 'variant', p.variant::text, 'fundingRealizedUsd', jsonb_build_object('atoms', (COALESCE(f.amount, 0) + COALESCE(nr.funding, 0))::text, 'scale', 6), 'rewardAccrualUsd', jsonb_build_object('atoms', COALESCE(v.reward, 0)::text, 'scale', 6), 'basisPnlUsd', jsonb_build_object('atoms', (COALESCE(v.basis, 0) + COALESCE(cb.basis, 0) + COALESCE(rb.basis, 0) + COALESCE(nr.basis, 0) + COALESCE(vb.basis, 0) + COALESCE(wr.basis, 0))::text, 'scale', 6), 'tradingFeesUsd', jsonb_build_object('atoms', COALESCE(lc.fees, 0)::text, 'scale', 6), 'borrowInterestUsd', jsonb_build_object('atoms', COALESCE(lc.borrow, 0)::text, 'scale', 6), 'netRecordedUsd', jsonb_build_object('atoms', (COALESCE(f.amount, 0) + COALESCE(nr.funding, 0) + COALESCE(v.reward, 0) + COALESCE(v.basis, 0) + COALESCE(cb.basis, 0) + COALESCE(rb.basis, 0) + COALESCE(nr.basis, 0) + COALESCE(vb.basis, 0) + COALESCE(wr.basis, 0) - COALESCE(lc.fees, 0) - COALESCE(lc.borrow, 0))::text, 'scale', 6), 'complete', false, 'scope', 'recorded_attribution_v1') AS item FROM portfolio_runs p LEFT JOIN funding f ON f.portfolio_run_id = p.id LEFT JOIN valuation v ON v.portfolio_run_id = p.id LEFT JOIN cross_basis cb ON cb.portfolio_run_id = p.id LEFT JOIN reverse_basis rb ON rb.portfolio_run_id = p.id LEFT JOIN nav_results nr ON nr.portfolio_run_id = p.id LEFT JOIN venue_basis vb ON vb.portfolio_run_id = p.id LEFT JOIN wallet_results wr ON wr.portfolio_run_id = p.id LEFT JOIN ledger_costs lc ON lc.portfolio_run_id = p.id WHERE p.strategy_run_id = 'local-paper-run' ORDER BY p.variant) SELECT COALESCE(jsonb_agg(item), '[]'::jsonb)::text AS body FROM items", [])
end

pub fn pnl_comparison(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH components AS (SELECT p.id, p.comparison_group_id, p.variant, COALESCE((SELECT sum(usd_value_atoms::numeric) FROM funding_payments WHERE portfolio_run_id = p.id), 0) AS funding, CASE WHEN p.variant = 'jitosol_carry' THEN COALESCE((SELECT sum(reward_accrual_usd_atoms::numeric) FROM valuation_events WHERE portfolio_run_id = p.id), 0) ELSE 0 END AS reward, CASE WHEN p.variant = 'jitosol_carry' THEN COALESCE((SELECT sum(basis_change_usd_atoms::numeric) FROM valuation_events WHERE portfolio_run_id = p.id), 0) ELSE 0 END AS basis, COALESCE((SELECT sum(le.usd_value_atoms::numeric) FROM ledger_entries le JOIN ledger_batches lb ON lb.id = le.ledger_batch_id WHERE lb.portfolio_run_id = p.id AND le.account_debit = 'trading_fees'), 0) AS fees FROM portfolio_runs p WHERE p.strategy_run_id = 'local-paper-run' AND p.comparison_group_id IS NOT NULL), totals AS (SELECT comparison_group_id, variant, funding + reward + basis - fees AS net FROM components), groups AS (SELECT g.id, g.mode, COALESCE(max(t.net) FILTER (WHERE t.variant = 'jitosol_carry'), 0) AS jito, COALESCE(max(t.net) FILTER (WHERE t.variant = 'sol_control'), 0) AS sol FROM comparison_groups g LEFT JOIN totals t ON t.comparison_group_id = g.id WHERE g.strategy_run_id = 'local-paper-run' GROUP BY g.id, g.mode), items AS (SELECT jsonb_build_object('comparisonGroupId', id, 'mode', mode::text, 'jitosolNetRecordedUsd', jsonb_build_object('atoms', jito::text, 'scale', 6), 'solNetRecordedUsd', jsonb_build_object('atoms', sol::text, 'scale', 6), 'jitosolIncrementalNetRecordedUsd', jsonb_build_object('atoms', (jito - sol)::text, 'scale', 6), 'complete', false, 'scope', 'recorded_attribution_v1') AS item FROM groups ORDER BY mode) SELECT COALESCE(jsonb_agg(item), '[]'::jsonb)::text AS body FROM items", [])
end

pub fn risk_events(pool :: PoolHandle, limit :: Int, offset :: Int) -> String ! String do
  read_body(pool, "WITH items AS (SELECT jsonb_build_object('id', id, 'portfolioRunId', portfolio_run_id, 'severity', severity, 'code', code, 'message', message, 'observedValue', observed_value, 'limitValue', limit_value, 'actionTaken', action_taken, 'createdAt', created_at, 'resolvedAt', resolved_at) AS item FROM risk_events ORDER BY created_at DESC, id DESC LIMIT $1::int OFFSET $2::int) SELECT jsonb_build_object('items', COALESCE(jsonb_agg(item), '[]'::jsonb), 'limit', $1::int, 'offset', $2::int)::text AS body FROM items", ["${limit}", "${offset}"])
end

pub fn risk_decisions(pool :: PoolHandle, limit :: Int, offset :: Int) -> String ! String do
  read_body(pool, "WITH items AS (SELECT jsonb_build_object('id', id, 'opportunityDecisionId', opportunity_decision_id, 'portfolioRunId', portfolio_run_id, 'sourceEventId', source_event_id, 'stateVersion', state_version::text, 'approved', approved, 'reasonCode', reason_code, 'action', action, 'limitsSnapshot', limits_snapshot, 'healthSnapshot', health_snapshot, 'createdAt', created_at) AS item FROM risk_decisions ORDER BY created_at DESC, id DESC LIMIT $1::int OFFSET $2::int) SELECT jsonb_build_object('items', COALESCE(jsonb_agg(item), '[]'::jsonb), 'limit', $1::int, 'offset', $2::int)::text AS body FROM items", ["${limit}", "${offset}"])
end

pub fn latest_reconciliation(pool :: PoolHandle) -> String ! String do
  read_body(pool, "SELECT COALESCE((SELECT jsonb_build_object('id', id, 'portfolioRunId', portfolio_run_id, 'executionMode', execution_mode::text, 'startedAt', started_at, 'completedAt', completed_at, 'walletSnapshot', wallet_snapshot, 'venueSnapshot', venue_snapshot, 'executorSnapshot', executor_snapshot, 'databaseSnapshot', database_snapshot, 'differences', differences, 'result', result) FROM reconciliations ORDER BY started_at DESC LIMIT 1), 'null'::jsonb)::text AS body", [])
end

pub fn adapter_status(pool :: PoolHandle, now_ms :: Int, max_age_ms :: Int) -> String ! String do
  read_body(pool, "WITH latest AS (SELECT source, event_type, observed_at_ms, source_slot, source_sequence, received_at FROM normalized_events ORDER BY observed_at_ms DESC LIMIT 1) SELECT jsonb_build_object('mode', 'read_only', 'schemaVersion', 1, 'seen', EXISTS(SELECT 1 FROM latest), 'connected', COALESCE((SELECT $1::bigint - observed_at_ms <= $2::bigint FROM latest), false), 'latest', COALESCE((SELECT jsonb_build_object('source', source, 'eventType', event_type, 'observedAtMs', observed_at_ms::text, 'sourceSlot', source_slot::text, 'sourceSequence', source_sequence, 'ageMs', GREATEST($1::bigint - observed_at_ms, 0)::text, 'receivedAt', received_at) FROM latest), 'null'::jsonb))::text AS body", ["${now_ms}", "${max_age_ms}"])
end
