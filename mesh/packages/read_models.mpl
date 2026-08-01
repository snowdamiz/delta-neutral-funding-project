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
# runState and portfolioRunIds are joined from the paper runs it owns. The
# Solana wallet-flow broker has its own paper account, so its state comes from
# that broker. Every catalog row has an independent, off-by-default control.
pub fn strategies(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH catalog(ordinal, id, display_name, family, legs, benchmark_id, mode) AS (VALUES (1, 'solana_wallet_flow_quant', 'Solana wallet-flow quant', 'signal', jsonb_build_array('follow configured wallet acquisitions', 'survival-score the exact mint', 'recoup cost at the ladder, ride the rest'), '', 'paper'), (2, 'cross_asset_funding', 'Cross-asset funding', 'carry', jsonb_build_array('long top-ranked spot asset', 'short matching perpetual'), '', 'paper'), (3, 'negative_funding_reverse', 'Negative-funding reverse carry', 'carry', jsonb_build_array('borrow and sell ranked spot asset', 'long matching perpetual'), '', 'paper'), (4, 'jitosol_nav_discount', 'JitoSOL NAV discount', 'arbitrage', jsonb_build_array('buy JitoSOL below protocol NAV', 'short NAV-equivalent SOL-PERP', 'redeem through the best modeled exit'), '', 'paper')), runs AS (SELECT variant::text AS id, jsonb_agg(id ORDER BY comparison_group_id, id) AS portfolio_run_ids, count(*) FILTER (WHERE state NOT IN ('idle', 'paused')) AS working, count(*) FILTER (WHERE state = 'paused') AS paused, count(*) AS total FROM portfolio_runs WHERE strategy_run_id = 'local-paper-run' GROUP BY variant), items AS (SELECT jsonb_build_object('id', c.id, 'displayName', c.display_name, 'family', c.family, 'legs', c.legs, 'benchmarkStrategyId', NULLIF(c.benchmark_id, ''), 'mode', CASE WHEN c.id = 'solana_wallet_flow_quant' THEN strategy_execution_mode(c.id) ELSE c.mode END, 'controlScope', 'strategy', 'enabled', control.enabled, 'runState', CASE WHEN c.id = 'solana_wallet_flow_quant' AND EXISTS (SELECT 1 FROM solana_paper_positions WHERE status = 'open') THEN 'active' WHEN COALESCE(r.working, 0) > 0 THEN 'active' WHEN NOT control.enabled THEN 'paused' WHEN c.id = 'solana_wallet_flow_quant' THEN 'idle' WHEN r.total IS NULL THEN 'unregistered' WHEN r.paused = r.total THEN 'paused' ELSE 'idle' END, 'portfolioRunIds', COALESCE(r.portfolio_run_ids, '[]'::jsonb)) AS item FROM catalog c JOIN strategy_controls control ON control.strategy_id = c.id LEFT JOIN runs r ON r.id = c.id ORDER BY c.ordinal) SELECT jsonb_build_object('schemaVersion', 2, 'strategies', COALESCE(jsonb_agg(item), '[]'::jsonb))::text AS body FROM items", [])
end

pub fn portfolios(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH items AS (SELECT jsonb_build_object('id', p.id, 'strategyRunId', p.strategy_run_id, 'comparisonGroupId', p.comparison_group_id, 'comparisonMode', g.mode::text, 'variant', p.variant::text, 'executionMode', p.execution_mode::text, 'state', p.state::text, 'stateVersion', p.state_version::text, 'randomState', p.random_state::text, 'initialCapitalUsd', jsonb_build_object('atoms', p.initial_capital_usd_micros::text, 'scale', 6), 'startedAt', p.started_at, 'endedAt', p.ended_at) AS item FROM portfolio_runs p LEFT JOIN comparison_groups g ON g.id = p.comparison_group_id WHERE p.strategy_run_id = 'local-paper-run' ORDER BY g.mode, p.variant) SELECT COALESCE(jsonb_agg(item), '[]'::jsonb)::text AS body FROM items", [])
end

pub fn portfolio(pool :: PoolHandle, portfolio_id :: String) -> String ! String do
  read_body(pool, "SELECT COALESCE((SELECT jsonb_build_object('id', p.id, 'strategyRunId', p.strategy_run_id, 'comparisonGroupId', p.comparison_group_id, 'comparisonMode', g.mode::text, 'variant', p.variant::text, 'executionMode', p.execution_mode::text, 'state', p.state::text, 'stateVersion', p.state_version::text, 'randomState', p.random_state::text, 'initialCapitalUsd', jsonb_build_object('atoms', p.initial_capital_usd_micros::text, 'scale', 6), 'startedAt', p.started_at, 'endedAt', p.ended_at) FROM portfolio_runs p LEFT JOIN comparison_groups g ON g.id = p.comparison_group_id WHERE p.id = $1), 'null'::jsonb)::text AS body", [portfolio_id])
end

pub fn positions(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH cross_items AS (SELECT p.variant::text AS variant, jsonb_build_object('portfolioRunId', p.id, 'variant', p.variant::text, 'state', p.state::text, 'asset', COALESCE(x.asset, ''), 'spotQuantity', jsonb_build_object('atoms', COALESCE(x.quantity_atoms, 0)::text, 'scale', 9), 'spotEquivalentSol', jsonb_build_object('atoms', COALESCE(x.quantity_atoms, 0)::text, 'scale', 9), 'perpShortSol', jsonb_build_object('atoms', COALESCE(x.quantity_atoms, 0)::text, 'scale', 9), 'netDeltaSol', jsonb_build_object('atoms', '0', 'scale', 9), 'deltaBps', '0', 'marginSnapshot', 'null'::jsonb) AS item FROM portfolio_runs p LEFT JOIN cross_asset_paper_positions x ON x.portfolio_run_id = p.id AND x.status IN ('open', 'exit_blocked') WHERE p.strategy_run_id = 'local-paper-run' AND p.variant = 'cross_asset_funding'), reverse_items AS (SELECT p.variant::text AS variant, jsonb_build_object('portfolioRunId', p.id, 'variant', p.variant::text, 'state', p.state::text, 'asset', COALESCE(x.asset, ''), 'spotQuantity', jsonb_build_object('atoms', (-COALESCE(x.quantity_atoms, 0))::text, 'scale', 9), 'spotEquivalentSol', jsonb_build_object('atoms', (-COALESCE(x.quantity_atoms, 0))::text, 'scale', 9), 'perpShortSol', jsonb_build_object('atoms', (-COALESCE(x.quantity_atoms, 0))::text, 'scale', 9), 'netDeltaSol', jsonb_build_object('atoms', '0', 'scale', 9), 'deltaBps', '0', 'marginSnapshot', 'null'::jsonb) AS item FROM portfolio_runs p LEFT JOIN reverse_carry_paper_positions x ON x.portfolio_run_id = p.id AND x.status IN ('open', 'exit_blocked') WHERE p.strategy_run_id = 'local-paper-run' AND p.variant = 'negative_funding_reverse'), nav_items AS (SELECT p.variant::text AS variant, jsonb_build_object('portfolioRunId', p.id, 'variant', p.variant::text, 'state', p.state::text, 'asset', 'JitoSOL', 'spotQuantity', jsonb_build_object('atoms', COALESCE(x.quantity_atoms, 0)::text, 'scale', 9), 'spotEquivalentSol', jsonb_build_object('atoms', COALESCE(x.hedge_quantity_atoms, 0)::text, 'scale', 9), 'perpShortSol', jsonb_build_object('atoms', COALESCE(x.hedge_quantity_atoms, 0)::text, 'scale', 9), 'netDeltaSol', jsonb_build_object('atoms', '0', 'scale', 9), 'deltaBps', '0', 'marginSnapshot', 'null'::jsonb) AS item FROM portfolio_runs p LEFT JOIN nav_discount_paper_positions x ON x.portfolio_run_id = p.id AND x.status IN ('open', 'exit_blocked') WHERE p.strategy_run_id = 'local-paper-run' AND p.variant = 'jitosol_nav_discount'), all_items AS (SELECT * FROM cross_items UNION ALL SELECT * FROM reverse_items UNION ALL SELECT * FROM nav_items) SELECT COALESCE(jsonb_agg(item ORDER BY variant), '[]'::jsonb)::text AS body FROM all_items", [])
end

pub fn orders(pool :: PoolHandle, limit :: Int, offset :: Int) -> String ! String do
  read_body(pool, "WITH items AS (SELECT jsonb_build_object('id', o.id, 'intentId', o.intent_id, 'intent', ei.intent_json, 'intentHash', ei.intent_hash, 'portfolioRunId', o.portfolio_run_id, 'executionMode', o.execution_mode::text, 'variant', o.variant::text, 'status', o.status, 'requestedQuantity', jsonb_build_object('atoms', o.requested_quantity_atoms, 'scale', 9), 'filledQuantity', jsonb_build_object('atoms', o.filled_quantity_atoms, 'scale', 9), 'externalId', o.external_id, 'createdAt', o.created_at, 'updatedAt', o.updated_at) AS item FROM orders o JOIN execution_intents ei ON ei.id = o.intent_id ORDER BY o.created_at DESC, o.id DESC LIMIT $1::int OFFSET $2::int) SELECT jsonb_build_object('items', COALESCE(jsonb_agg(item), '[]'::jsonb), 'limit', $1::int, 'offset', $2::int)::text AS body FROM items", ["${limit}", "${offset}"])
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




pub fn jitosol(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH counterfactuals AS (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'portfolioRunId', portfolio_run_id, 'sourceEventId', source_event_id, 'state', state, 'requestedEpoch', requested_epoch::text, 'availableEpoch', available_epoch::text, 'jitosolQuantity', jsonb_build_object('atoms', jitosol_quantity_atoms, 'scale', 9), 'hedgeQuantity', jsonb_build_object('atoms', hedge_quantity_atoms, 'scale', 9), 'protocolRedemptionSol', jsonb_build_object('atoms', protocol_redemption_lamports, 'scale', 9), 'withdrawalFeeSol', jsonb_build_object('atoms', withdrawal_fee_lamports, 'scale', 9), 'cooldownFundingUsd', jsonb_build_object('atoms', cooldown_funding_usd_micros, 'scale', 6), 'netUsd', jsonb_build_object('atoms', net_usd_micros, 'scale', 6), 'updatedAt', updated_at) ORDER BY created_at DESC), '[]'::jsonb) AS value FROM direct_unstake_counterfactuals) SELECT jsonb_build_object('directUnstakeCounterfactuals', counterfactuals.value)::text AS body FROM counterfactuals", [])
end

pub fn pnl(pool :: PoolHandle) -> String ! String do
  read_body(pool, "WITH funding AS (SELECT portfolio_run_id, COALESCE(sum(usd_value_atoms::numeric), 0) AS amount FROM funding_payments GROUP BY portfolio_run_id), cross_basis AS (SELECT portfolio_run_id, COALESCE(sum(realized_basis_usd_micros), 0) AS basis FROM cross_asset_paper_positions GROUP BY portfolio_run_id), reverse_basis AS (SELECT portfolio_run_id, COALESCE(sum(realized_basis_usd_micros), 0) AS basis FROM reverse_carry_paper_positions GROUP BY portfolio_run_id), nav_results AS (SELECT portfolio_run_id, COALESCE(sum(realized_basis_usd_micros), 0) AS basis, COALESCE(sum(realized_funding_usd_micros), 0) AS funding FROM nav_discount_paper_positions GROUP BY portfolio_run_id), ledger_costs AS (SELECT lb.portfolio_run_id, COALESCE(sum(le.usd_value_atoms::numeric) FILTER (WHERE le.account_debit = 'trading_fees'), 0) AS fees, COALESCE(sum(le.usd_value_atoms::numeric) FILTER (WHERE le.account_debit = 'borrow_interest_expense'), 0) AS borrow FROM ledger_entries le JOIN ledger_batches lb ON lb.id = le.ledger_batch_id GROUP BY lb.portfolio_run_id), items AS (SELECT jsonb_build_object('portfolioRunId', p.id, 'variant', p.variant::text, 'fundingRealizedUsd', jsonb_build_object('atoms', (COALESCE(f.amount, 0) + COALESCE(nr.funding, 0))::text, 'scale', 6), 'rewardAccrualUsd', jsonb_build_object('atoms', '0', 'scale', 6), 'basisPnlUsd', jsonb_build_object('atoms', (COALESCE(cb.basis, 0) + COALESCE(rb.basis, 0) + COALESCE(nr.basis, 0))::text, 'scale', 6), 'tradingFeesUsd', jsonb_build_object('atoms', COALESCE(lc.fees, 0)::text, 'scale', 6), 'borrowInterestUsd', jsonb_build_object('atoms', COALESCE(lc.borrow, 0)::text, 'scale', 6), 'netRecordedUsd', jsonb_build_object('atoms', (COALESCE(f.amount, 0) + COALESCE(nr.funding, 0) + COALESCE(cb.basis, 0) + COALESCE(rb.basis, 0) + COALESCE(nr.basis, 0) - COALESCE(lc.fees, 0) - COALESCE(lc.borrow, 0))::text, 'scale', 6), 'complete', false, 'scope', 'recorded_attribution_v1') AS item FROM portfolio_runs p LEFT JOIN funding f ON f.portfolio_run_id = p.id LEFT JOIN cross_basis cb ON cb.portfolio_run_id = p.id LEFT JOIN reverse_basis rb ON rb.portfolio_run_id = p.id LEFT JOIN nav_results nr ON nr.portfolio_run_id = p.id LEFT JOIN ledger_costs lc ON lc.portfolio_run_id = p.id WHERE p.strategy_run_id = 'local-paper-run' ORDER BY p.variant) SELECT COALESCE(jsonb_agg(item), '[]'::jsonb)::text AS body FROM items", [])
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
