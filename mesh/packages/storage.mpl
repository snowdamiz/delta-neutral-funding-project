from Packages.BrokerPaper import fill_status_name
from Packages.Finance import Lamports, PriceMicros, QuantityAtoms, RatePpm, TokenAtoms, UsdMicros, lamports_to_usd
from Packages.Opportunity import OpportunitySet
from Packages.PaperEngine import EntryOutcome, LegFill, PaperAction, PaperPlan, PaperPosition, PaperRuntime, PaperVariant, PositionPlan, action_name, outcome_name, variant_from_name, variant_name
from Packages.ProtocolContracts import MarketSnapshot
from Packages.StateMachine import PortfolioState, state_from_name, state_name

fn bool_string(value :: Bool) -> String do
  if value do
    "true"
  else
    "false"
  end
end

fn reason(eligible :: Bool) -> String do
  if eligible do
    "positive_net_carry"
  else
    "entry_gate_failed"
  end
end

fn required_int(value :: String, field :: String) -> Int ! String do
  case String.to_int(value) do
    Some(parsed) -> Ok(parsed)
    None -> Err("database returned invalid ${field}")
  end
end

pub fn load_paper_runtime(pool :: PoolHandle, portfolio_id :: String, now_ms :: Int, max_age_ms :: Int) -> PaperRuntime ! String do
  let rows = Pool.query(pool, "SELECT p.state::text, p.state_version::text, p.random_state::text, (c.pause_entries OR c.pause_all)::text AS paused FROM portfolio_runs p CROSS JOIN control_state c WHERE p.id = $1", [portfolio_id]) ?
  if List.length(rows) != 1 do
    return Err("paper portfolio not found")
  end
  let row = List.head(rows)
  let state = state_from_name(Map.get(row, "state")) ?
  let state_version = required_int(Map.get(row, "state_version"), "state version") ?
  let random_state = required_int(Map.get(row, "random_state"), "random state") ?
  Ok(PaperRuntime {
    now_ms : now_ms,
    max_age_ms : max_age_ms,
    paused : Map.get(row, "paused") == "true",
    state : state,
    state_version : state_version,
    random_state : random_state
  })
end

fn spot_requested_atoms(snapshot :: MarketSnapshot, result :: OpportunitySet, variant :: PaperVariant) -> Int do
  case variant do
    SolControl -> result.hedge_lamports.atoms
    JitoSolCarry -> snapshot.jitosol_atoms.atoms
  end
end

fn spot_quote_atoms(snapshot :: MarketSnapshot, variant :: PaperVariant) -> Int do
  case variant do
    SolControl -> snapshot.sol_spot_ask_price_usd_micros.atoms
    JitoSolCarry -> snapshot.jitosol_spot_ask_price_usd_micros.atoms
  end
end

fn paper_intent(
  source_event_id :: String,
  portfolio_id :: String,
  variant :: String,
  operation :: String,
  leg :: String,
  asset :: String,
  side :: String,
  requested_atoms :: Int,
  quoted_price_atoms :: Int
) -> String do
  json {
    schemaVersion : 1,
    sourceEventId : source_event_id,
    portfolioRunId : portfolio_id,
    executionMode : "paper",
    variant : variant,
    operation : operation,
    leg : leg,
    asset : asset,
    side : side,
    requestedQuantityAtoms : "${requested_atoms}",
    quotedPriceAtoms : "${quoted_price_atoms}"
  }
end

pub fn persist_paper_plan(
  pool :: PoolHandle,
  snapshot :: MarketSnapshot,
  result :: OpportunitySet,
  portfolio_id :: String,
  runtime :: PaperRuntime,
  plan :: PaperPlan
) -> Int ! String do
  if plan.outcome == EntrySkipped do
    return Ok(0)
  end

  let variant = variant_name(plan.variant)
  let spot_requested = spot_requested_atoms(snapshot, result, plan.variant)
  let perp_requested = result.hedge_lamports.atoms
  let spot_intent = paper_intent(
    snapshot.event_id,
    portfolio_id,
    variant,
    "OPEN",
    "SPOT",
    plan.spot_asset,
    "BUY",
    spot_requested,
    spot_quote_atoms(snapshot, plan.variant)
  )
  let perp_intent = paper_intent(
    snapshot.event_id,
    portfolio_id,
    variant,
    "OPEN",
    "PERP",
    "PERP-SOL",
    "SELL",
    perp_requested,
    snapshot.perp_bid_price_usd_micros.atoms
  )
  let plan_json = json {
    variant : variant,
    outcome : outcome_name(plan.outcome),
    reason : plan.reason,
    nextState : state_name(plan.next_state),
    nextRandomState : "${plan.next_random_state}",
    spotPlaced : plan.spot_fill.placed,
    spotStatus : fill_status_name(plan.spot_fill.status),
    spotAsset : plan.spot_asset,
    spotRequestedQuantityAtoms : "${spot_requested}",
    spotFilledQuantityAtoms : "${plan.spot_fill.filled_quantity.atoms}",
    spotPriceAtoms : "${plan.spot_fill.average_price.atoms}",
    spotGrossUsdAtoms : "${plan.spot_fill.gross_usd.atoms}",
    spotFeeUsdAtoms : "${plan.spot_fill.fee_usd.atoms}",
    perpPlaced : plan.perp_fill.placed,
    perpStatus : fill_status_name(plan.perp_fill.status),
    perpRequestedQuantityAtoms : "${perp_requested}",
    perpFilledQuantityAtoms : "${plan.perp_fill.filled_quantity.atoms}",
    perpPriceAtoms : "${plan.perp_fill.average_price.atoms}",
    perpGrossUsdAtoms : "${plan.perp_fill.gross_usd.atoms}",
    perpFeeUsdAtoms : "${plan.perp_fill.fee_usd.atoms}"
  }
  let rows = Pool.query(pool, "SELECT apply_paper_plan($1, $2::bigint, $3, $4::jsonb, $5::jsonb, $6, $7::jsonb, $8)::text AS applied", [
    portfolio_id,
    "${runtime.state_version}",
    snapshot.event_id,
    plan_json,
    spot_intent,
    spot_intent |> Crypto.sha256,
    perp_intent,
    perp_intent |> Crypto.sha256
  ]) ?
  if List.length(rows) != 1 do
    return Err("database returned invalid paper plan result")
  end
  if Map.get(List.head(rows), "applied") == "true" do
    Ok(1)
  else
    Err("paper portfolio state changed")
  end
end

pub fn load_paper_position(pool :: PoolHandle, portfolio_id :: String) -> PaperPosition ! String do
  let rows = Pool.query(pool, "WITH balances AS (SELECT COALESCE(sum(CASE WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'BUY' THEN f.quantity_atoms::numeric WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'SELL' THEN -f.quantity_atoms::numeric ELSE 0 END), 0)::text AS spot_quantity, COALESCE(sum(CASE WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'SELL' THEN f.quantity_atoms::numeric WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'BUY' THEN -f.quantity_atoms::numeric ELSE 0 END), 0)::text AS perp_short_quantity FROM fills f JOIN orders o ON o.id = f.order_id JOIN execution_intents ei ON ei.id = o.intent_id WHERE f.portfolio_run_id = $1), last_open AS (SELECT ne.observed_at_ms, od.nav_lamports, CASE WHEN p.variant = 'sol_control' THEN '1000000000' ELSE trunc((ne.canonical_payload#>>'{payload,jitosolSpotBidPriceUsdMicros}')::numeric * 1000000000 / (ne.canonical_payload#>>'{payload,solPriceUsdMicros}')::numeric)::text END AS market_rate FROM fills f JOIN orders o ON o.id = f.order_id JOIN execution_intents ei ON ei.id = o.intent_id JOIN normalized_events ne ON ne.id = f.source_snapshot_id JOIN opportunity_decisions od ON od.source_event_id = ne.id AND od.variant = ei.variant JOIN portfolio_runs p ON p.id = f.portfolio_run_id WHERE f.portfolio_run_id = $1 AND ei.operation = 'OPEN' AND ei.leg = 'SPOT' ORDER BY ne.observed_at_ms DESC LIMIT 1), latest_position AS (SELECT observed_at_ms, protocol_nav_rate_atoms, market_sell_rate_atoms FROM position_snapshots WHERE portfolio_run_id = $1 ORDER BY observed_at_ms DESC LIMIT 1) SELECT p.variant::text, p.state_version::text, p.random_state::text, b.spot_quantity, b.perp_short_quantity, CASE WHEN COALESCE(lp.observed_at_ms, -1) >= lo.observed_at_ms THEN lp.protocol_nav_rate_atoms ELSE lo.nav_lamports END AS prior_nav, CASE WHEN COALESCE(lp.observed_at_ms, -1) >= lo.observed_at_ms THEN lp.market_sell_rate_atoms ELSE lo.market_rate END AS prior_market_rate FROM portfolio_runs p CROSS JOIN balances b CROSS JOIN last_open lo LEFT JOIN latest_position lp ON true WHERE p.id = $1 AND p.state = 'hedged'", [portfolio_id]) ?
  if List.length(rows) != 1 do
    return Err("hedged paper position not found")
  end
  let row = List.head(rows)
  Ok(PaperPosition {
    variant : variant_from_name(Map.get(row, "variant")) ?,
    spot_quantity : TokenAtoms {
      atoms : required_int(Map.get(row, "spot_quantity"), "spot quantity") ?
    },
    perp_short_quantity : Lamports {
      atoms : required_int(Map.get(row, "perp_short_quantity"), "perp quantity") ?
    },
    prior_nav_lamports : Lamports {
      atoms : required_int(Map.get(row, "prior_nav"), "prior NAV") ?
    },
    prior_market_rate_lamports : Lamports {
      atoms : required_int(Map.get(row, "prior_market_rate"), "prior market rate") ?
    },
    state_version : required_int(Map.get(row, "state_version"), "state version") ?,
    random_state : required_int(Map.get(row, "random_state"), "random state") ?
  })
end

fn position_operation(action :: PaperAction) -> String do
  case action do
    HoldPosition -> "REBALANCE"
    RebalancePerp -> "REBALANCE"
    ExitPosition -> "CLOSE"
    EmergencyPosition -> "EMERGENCY_FLATTEN"
  end
end

pub fn persist_position_plan(pool :: PoolHandle,
snapshot :: MarketSnapshot,
portfolio_id :: String,
position :: PaperPosition,
plan :: PositionPlan) -> Int ! String do
  let operation = position_operation(plan.action)
  let variant = variant_name(position.variant)
  let spot_intent = paper_intent(snapshot.event_id,
  portfolio_id,
  variant,
  operation,
  "SPOT",
  plan.spot_asset,
  "SELL",
  plan.spot_requested_quantity.atoms,
  if position.variant == SolControl do
    snapshot.sol_spot_bid_price_usd_micros.atoms
  else
    snapshot.jitosol_spot_bid_price_usd_micros.atoms
  end)
  let perp_intent = paper_intent(snapshot.event_id,
  portfolio_id,
  variant,
  operation,
  "PERP",
  "PERP-SOL",
  plan.perp_side,
  plan.perp_requested_quantity.atoms,
  if plan.perp_side == "SELL" do
    snapshot.perp_bid_price_usd_micros.atoms
  else
    snapshot.perp_ask_price_usd_micros.atoms
  end)
  let reward_usd = (plan.valuation.reward_sol_lamports
    |> lamports_to_usd(snapshot.sol_price_usd_micros, :toward_zero)) ?
  let basis_usd = (plan.valuation.basis_sol_lamports
    |> lamports_to_usd(snapshot.sol_price_usd_micros, :toward_zero)) ?
  let plan_json = json {
    variant : variant,
    action : action_name(plan.action),
    reason : plan.reason,
    nextState : state_name(plan.next_state),
    nextRandomState : "${plan.next_random_state}",
    observedAtMs : "${snapshot.observed_at_ms}",
    spotAsset : plan.spot_asset,
    currentSpotQuantityAtoms : "${position.spot_quantity.atoms}",
    nextSpotQuantityAtoms : "${plan.next_spot_quantity.atoms}",
    nextPerpShortQuantityAtoms : "${plan.next_perp_short_quantity.atoms}",
    protocolNavLamports : "${plan.valuation.protocol_nav_lamports.atoms}",
    marketRateLamports : "${plan.valuation.market_rate_lamports.atoms}",
    spotEquivalentLamports : "${plan.valuation.spot_equivalent_lamports.atoms}",
    deltaLamports : "${plan.valuation.delta_lamports.atoms}",
    deltaBps : "${plan.valuation.delta_bps}",
    rewardSolLamports : "${plan.valuation.reward_sol_lamports.atoms}",
    basisSolLamports : "${plan.valuation.basis_sol_lamports.atoms}",
    rewardUsdMicros : "${reward_usd.atoms}",
    basisUsdMicros : "${basis_usd.atoms}",
    spotPlaced : plan.spot_fill.placed,
    spotStatus : fill_status_name(plan.spot_fill.status),
    spotRequestedQuantityAtoms : "${plan.spot_requested_quantity.atoms}",
    spotFilledQuantityAtoms : "${plan.spot_fill.filled_quantity.atoms}",
    spotPriceAtoms : "${plan.spot_fill.average_price.atoms}",
    spotGrossUsdAtoms : "${plan.spot_fill.gross_usd.atoms}",
    spotFeeUsdAtoms : "${plan.spot_fill.fee_usd.atoms}",
    perpPlaced : plan.perp_fill.placed,
    perpSide : plan.perp_side,
    perpStatus : fill_status_name(plan.perp_fill.status),
    perpRequestedQuantityAtoms : "${plan.perp_requested_quantity.atoms}",
    perpFilledQuantityAtoms : "${plan.perp_fill.filled_quantity.atoms}",
    perpPriceAtoms : "${plan.perp_fill.average_price.atoms}",
    perpGrossUsdAtoms : "${plan.perp_fill.gross_usd.atoms}",
    perpFeeUsdAtoms : "${plan.perp_fill.fee_usd.atoms}"
  }
  let rows = Pool.query(pool, "SELECT apply_paper_position_plan($1, $2::bigint, $3, $4::jsonb, $5::jsonb, $6, $7::jsonb, $8)::text AS applied", [
    portfolio_id,
    "${position.state_version}",
    snapshot.event_id,
    plan_json,
    spot_intent,
    spot_intent |> Crypto.sha256,
    perp_intent,
    perp_intent |> Crypto.sha256
  ]) ?
  if List.length(rows) != 1 do
    return Err("database returned invalid paper position result")
  end
  if Map.get(List.head(rows), "applied") == "true" do
    Ok(1)
  else
    Err("paper portfolio state changed")
  end
end

pub fn persist_opportunities(pool :: PoolHandle, body :: String, snapshot :: MarketSnapshot, result :: OpportunitySet, config_hash :: String) -> Int ! String do
  let rows = Pool.query(pool, "WITH source_event AS (INSERT INTO normalized_events (id, schema_version, event_type, source, observed_at_ms, source_slot, source_sequence, idempotency_key, raw_payload_hash, canonical_payload) VALUES ($1, 1, 'MarketSnapshot', $2, $3::bigint, $4::bigint, $5, $6, $7, $8::jsonb) ON CONFLICT (idempotency_key) DO NOTHING RETURNING id, raw_payload_hash, canonical_payload), recorded_event AS (SELECT id, raw_payload_hash, canonical_payload FROM source_event UNION ALL SELECT id, raw_payload_hash, canonical_payload FROM normalized_events WHERE idempotency_key = $6), decisions AS (INSERT INTO opportunity_decisions (id, source_event_id, variant, observed_at_ms, nav_lamports, hedge_lamports, expected_funding_usd_micros, nav_reward_usd_micros, net_carry_usd_micros, eligible, reason_code, config_hash) SELECT $1 || ':sol', id, 'sol_control'::strategy_variant, $3::bigint, $9, $10, $11, '0', $12, $13::boolean, $14, $19 FROM source_event UNION ALL SELECT $1 || ':jitosol', id, 'jitosol_carry'::strategy_variant, $3::bigint, $9, $10, $11, $15, $16, $17::boolean, $18, $19 FROM source_event RETURNING id) SELECT (SELECT count(*)::text FROM decisions) AS inserted, COALESCE((SELECT bool_and(id = $1 AND raw_payload_hash = $7 AND canonical_payload = $8::jsonb)::text FROM recorded_event), 'false') AS event_matches", [
    snapshot.event_id,
    snapshot.source,
    "${snapshot.observed_at_ms}",
    "${snapshot.source_slot}",
    snapshot.source_sequence,
    snapshot.idempotency_key,
    snapshot.raw_payload_hash,
    body,
    "${result.nav_lamports.atoms}",
    "${result.hedge_lamports.atoms}",
    "${result.expected_funding_usd_micros.atoms}",
    "${result.sol_net_carry_usd_micros.atoms}",
    bool_string(result.sol_eligible),
    reason(result.sol_eligible),
    "${result.nav_reward_usd_micros.atoms}",
    "${result.jitosol_net_carry_usd_micros.atoms}",
    bool_string(result.jitosol_eligible),
    reason(result.jitosol_eligible),
    config_hash
  ]) ?
  if List.length(rows) == 0 do
    Ok(0)
  else
    if Map.get(List.head(rows), "event_matches") != "true" do
      return Err("idempotency key reused for a different event")
    end
    case String.to_int(Map.get(List.head(rows), "inserted")) do
      Some(count) -> Ok(count)
      None -> Err("database returned invalid insert count")
    end
  end
end

fn rows_to_json(rows, index :: Int, acc :: List<String>) -> String do
  if index >= List.length(rows) do
    "[${String.join(acc, ",")}]"
  else
    let row = List.get(rows, index)
    let encoded = json {
      id : Map.get(row, "id"),
      sourceEventId : Map.get(row, "source_event_id"),
      variant : Map.get(row, "variant"),
      observedAtMs : Map.get(row, "observed_at_ms"),
      navLamports : Map.get(row, "nav_lamports"),
      hedgeLamports : Map.get(row, "hedge_lamports"),
      expectedFundingUsdMicros : Map.get(row, "expected_funding_usd_micros"),
      navRewardUsdMicros : Map.get(row, "nav_reward_usd_micros"),
      netCarryUsdMicros : Map.get(row, "net_carry_usd_micros"),
      eligible : Map.get(row, "eligible") == "true",
      reasonCode : Map.get(row, "reason_code")
    }
    rows_to_json(rows, index + 1, List.append(acc, encoded))
  end
end

pub fn list_opportunities(pool :: PoolHandle) -> String ! String do
  let rows = Pool.query(pool, "SELECT id, source_event_id, variant::text, observed_at_ms::text, nav_lamports, hedge_lamports, expected_funding_usd_micros, nav_reward_usd_micros, net_carry_usd_micros, eligible::text, reason_code FROM opportunity_decisions ORDER BY observed_at_ms DESC, variant LIMIT 100", []) ?
  Ok(rows |> rows_to_json(0, List.new()))
end

pub fn bootstrap_paper_runs(pool :: PoolHandle, code_commit :: String, mesh_commit :: String, config_hash :: String) -> Int ! String do
  "WITH build AS (INSERT INTO build_manifests (id, code_commit, mesh_commit, schema_version, config_hash) VALUES ('local-paper-build', $1, $2, 5, $3) ON CONFLICT (id) DO UPDATE SET code_commit = EXCLUDED.code_commit, mesh_commit = EXCLUDED.mesh_commit, schema_version = EXCLUDED.schema_version, config_hash = EXCLUDED.config_hash RETURNING id), run AS (INSERT INTO strategy_runs (id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version) SELECT 'local-paper-run', 'paper', $3, id, 42, 'xorshift64star-v1' FROM build ON CONFLICT (id) DO NOTHING RETURNING id), portfolios AS (INSERT INTO portfolio_runs (id, strategy_run_id, variant, execution_mode, initial_capital_usd_micros) VALUES ('local-sol-control', 'local-paper-run', 'sol_control', 'paper', 1000000000), ('local-jitosol-carry', 'local-paper-run', 'jitosol_carry', 'paper', 1000000000) ON CONFLICT (id) DO NOTHING RETURNING id), batches AS (INSERT INTO ledger_batches (id, portfolio_run_id, event_type, event_id, batch_hash) SELECT id || ':opening', id, 'opening_capital', id || ':opening', repeat('0', 64) FROM portfolios RETURNING id, portfolio_run_id) INSERT INTO ledger_entries (ledger_batch_id, account_debit, account_credit, asset, amount_atoms, usd_value_atoms) SELECT id, 'paper_cash', 'paper_equity', 'USDC', '1000000000', '1000000000' FROM batches" |2> Pool.execute(pool, [code_commit, mesh_commit, config_hash])
end
