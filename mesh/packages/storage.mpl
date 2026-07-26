from Packages.Accounting import realized_funding_usd, start_direct_unstake
from Packages.BrokerPaper import fill_status_name
from Packages.ExecutionIntents import ExecutionIntent, canonical_execution_intent
from Packages.Finance import Lamports, PriceMicros, QuantityAtoms, RatePpm, TokenAtoms, UsdMicros, lamports_to_usd
from Packages.Opportunity import OpportunitySet
from Packages.PaperEngine import EntryOutcome, LegFill, PaperAction, PaperPlan, PaperPosition, PaperRuntime, PaperVariant, PositionPlan, action_name, outcome_name, variant_from_name, variant_name
from Packages.ProtocolContracts import FundingSettlement, MarketSnapshot, OracleStatus, ShadowResult
from Packages.RiskEngine import margin_ratio_ppm
from Packages.RuntimeConfig import load_runtime_config, runtime_config_hash
from Packages.StateMachine import PortfolioState, state_from_name, state_name

fn bool_string(value :: Bool) -> String do
  if value do
    "true"
  else
    "false"
  end
end

pub fn persist_shadow_result(
  pool :: PoolHandle,
  result :: ShadowResult
) -> String ! String do
  let rows = Pool.query(
    pool,
    "SELECT record_shadow_result($1, $2::jsonb) AS status",
    [result.binding_hash, result.body]
  ) ?
  if List.length(rows) != 1 do
    Err("database returned invalid shadow result")
  else
    Ok(Map.get(List.head(rows), "status"))
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

fn persist_risk_decision(
  pool :: PoolHandle,
  snapshot :: MarketSnapshot,
  portfolio_id :: String,
  runtime :: PaperRuntime,
  approved :: Bool,
  reason_code :: String,
  action :: String
) -> Int ! String do
  let limits = json {
    maxSourceAgeMs : "${runtime.max_age_ms}",
    minimumMarginRatioPpm : "${runtime.minimum_margin_ratio_ppm}",
    minimumLiquidationDistanceBps : "${runtime.minimum_liquidation_distance_bps}",
    rebalanceDeltaBps : "${runtime.rebalance_delta_bps}"
  }
  let health = json {
    observedAtMs : "${snapshot.observed_at_ms}",
    evaluatedAtMs : "${runtime.now_ms}",
    oracleValid : snapshot.oracle_status == OracleValid,
    collateralUsdMicros : "${snapshot.collateral_usd_micros.atoms}",
    maintenanceRequirementUsdMicros : "${snapshot.maintenance_requirement_usd_micros.atoms}",
    marginRatioPpm : "${margin_ratio_ppm(
      snapshot.collateral_usd_micros,
      snapshot.maintenance_requirement_usd_micros
    ) ?}",
    liquidationDistanceBps : "${snapshot.liquidation_distance_bps}",
    solExitDepthLamports : "${snapshot.sol_exit_depth_lamports.atoms}",
    jitosolExitDepthLamports : "${snapshot.jitosol_exit_depth_lamports.atoms}",
    perpExitDepthLamports : "${snapshot.perp_exit_depth_lamports.atoms}"
  }
  let rows = Pool.query(pool, "SELECT record_paper_risk_decision($1, $2, $3::bigint, $4::boolean, $5, $6, $7::jsonb, $8::jsonb)::text AS inserted", [
    portfolio_id,
    snapshot.event_id,
    "${runtime.state_version}",
    bool_string(approved),
    reason_code,
    action,
    limits,
    health
  ]) ?
  if List.length(rows) != 1 do
    Err("database returned invalid risk decision result")
  else
    Ok(if Map.get(List.head(rows), "inserted") == "true" do 1 else 0 end)
  end
end

pub struct FundingPersistence do
  inserted_event :: Bool
  payments :: Int
  counterfactual_payments :: Int
end

pub type PendingPaperAction do
  NoPendingAction
  PendingAction(String, String)
end

pub fn load_pending_paper_action(
  pool :: PoolHandle,
  portfolio_id :: String
) -> PendingPaperAction ! String do
  let rows = Pool.query(pool, "SELECT action, reason FROM operator_portfolio_actions WHERE portfolio_run_id = $1 AND status = 'pending'", [
    portfolio_id
  ]) ?
  if List.length(rows) == 0 do
    Ok(NoPendingAction)
  else
    if List.length(rows) != 1 do
      return Err("database returned multiple pending paper actions")
    end
    let row = List.head(rows)
    Ok(PendingAction(Map.get(row, "action"), Map.get(row, "reason")))
  end
end

pub fn load_paper_runtime(
  pool :: PoolHandle,
  portfolio_id :: String,
  now_ms :: Int,
  max_age_ms :: Int,
  minimum_margin_ratio_ppm :: Int,
  minimum_liquidation_distance_bps :: Int,
  rebalance_delta_bps :: Int
) -> PaperRuntime ! String do
  let rows = Pool.query(pool, "SELECT p.state::text, p.state_version::text, p.random_state::text, (c.pause_entries OR c.pause_all)::text AS paused, c.pause_all::text FROM portfolio_runs p CROSS JOIN control_state c WHERE p.id = $1", [portfolio_id]) ?
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
    pause_all : Map.get(row, "pause_all") == "true",
    minimum_margin_ratio_ppm : minimum_margin_ratio_ppm,
    minimum_liquidation_distance_bps : minimum_liquidation_distance_bps,
    rebalance_delta_bps : rebalance_delta_bps,
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

fn execution_instrument(asset :: String, leg :: String) -> String do
  if leg == "PERP" do
    "SOL-PERP"
  else
    if asset == "JitoSOL" do "JUPITER:JITOSOL-USDC" else "JUPITER:SOL-USDC" end
  end
end

fn paper_intent(
  intent_id :: String,
  source_event_id :: String,
  portfolio_id :: String,
  state_version :: Int,
  observed_at_ms :: Int,
  variant :: String,
  operation :: String,
  leg :: String,
  asset :: String,
  side :: String,
  requested_atoms :: Int,
  quoted_price_atoms :: Int,
  placed :: Bool
) -> String ! String do
  if placed == false do
    return Ok("{}")
  end
  let config = load_runtime_config() ?
  ExecutionIntent {
    intent_id : intent_id,
    strategy_run_id : "local-paper-run",
    state_version : state_version,
    variant : variant,
    operation : operation,
    leg : leg,
    instrument : asset |> execution_instrument(leg),
    side : side,
    max_quantity_atoms : requested_atoms,
    limit_price_atoms : quoted_price_atoms,
    max_slippage_bps : config.maximum_execution_slippage_bps,
    reduce_only : leg == "PERP" && operation != "OPEN",
    expires_at_ms : (observed_at_ms
      |> Checked.add(config.execution_intent_ttl_ms)) ?,
    policy_profile : config.execution_policy_profile,
    snapshot_ids : [source_event_id],
    config_hash : config |> runtime_config_hash
  }
    |> canonical_execution_intent
end

fn entry_record(
  snapshot :: MarketSnapshot,
  result :: OpportunitySet,
  portfolio_id :: String,
  runtime :: PaperRuntime,
  plan :: PaperPlan
) -> String ! String do
  let variant = plan.variant |> variant_name
  let intent_base = "${snapshot.event_id}:${portfolio_id}:${variant}"
  let spot_requested = spot_requested_atoms(snapshot, result, plan.variant)
  let spot_intent = paper_intent(
    "${intent_base}:spot:intent",
    snapshot.event_id,
    portfolio_id,
    runtime.state_version,
    snapshot.observed_at_ms,
    variant,
    "OPEN",
    "SPOT",
    plan.spot_asset,
    "BUY",
    spot_requested,
    spot_quote_atoms(snapshot, plan.variant),
    plan.spot_fill.placed
  ) ?
  let perp_intent = paper_intent(
    "${intent_base}:perp:intent",
    snapshot.event_id,
    portfolio_id,
    runtime.state_version,
    snapshot.observed_at_ms,
    variant,
    "OPEN",
    "PERP",
    "PERP-SOL",
    "SELL",
    result.hedge_lamports.atoms,
    snapshot.perp_bid_price_usd_micros.atoms,
    plan.perp_fill.placed
  ) ?
  Ok(json {
    portfolioRunId : portfolio_id,
    expectedStateVersion : "${runtime.state_version}",
    plan : json {
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
      perpRequestedQuantityAtoms : "${result.hedge_lamports.atoms}",
      perpFilledQuantityAtoms : "${plan.perp_fill.filled_quantity.atoms}",
      perpPriceAtoms : "${plan.perp_fill.average_price.atoms}",
      perpGrossUsdAtoms : "${plan.perp_fill.gross_usd.atoms}",
      perpFeeUsdAtoms : "${plan.perp_fill.fee_usd.atoms}"
    },
    spotIntent : spot_intent,
    spotIntentHash : spot_intent |> Crypto.sha256,
    perpIntent : perp_intent,
    perpIntentHash : perp_intent |> Crypto.sha256
  })
end

pub fn persist_paper_plan(
  pool :: PoolHandle,
  snapshot :: MarketSnapshot,
  result :: OpportunitySet,
  portfolio_id :: String,
  runtime :: PaperRuntime,
  plan :: PaperPlan
) -> Int ! String do
  persist_risk_decision(
    pool,
    snapshot,
    portfolio_id,
    runtime,
    plan.outcome != EntrySkipped,
    plan.reason,
    if plan.outcome == EntrySkipped do "skip" else "entry" end
  ) ?
  if plan.outcome == EntrySkipped do
    return Ok(0)
  end

  let record = (plan |5> entry_record(
    snapshot,
    result,
    portfolio_id,
    runtime
  )) ?
  let rows = Pool.query(pool, "SELECT apply_paper_plan($1::jsonb->>'portfolioRunId', ($1::jsonb->>'expectedStateVersion')::bigint, $2, $1::jsonb->'plan', $1::jsonb->'spotIntent', ($1::jsonb->>'spotIntentHash')::char(64), $1::jsonb->'perpIntent', ($1::jsonb->>'perpIntentHash')::char(64))::text AS applied", [
    record,
    snapshot.event_id
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

pub fn persist_synchronized_paper_entries(
  pool :: PoolHandle,
  comparison_group_id :: String,
  snapshot :: MarketSnapshot,
  result :: OpportunitySet,
  sol_portfolio_id :: String,
  sol_runtime :: PaperRuntime,
  sol_plan :: PaperPlan,
  jito_portfolio_id :: String,
  jito_runtime :: PaperRuntime,
  jito_plan :: PaperPlan
) -> Int ! String do
  persist_risk_decision(
    pool,
    snapshot,
    sol_portfolio_id,
    sol_runtime,
    sol_plan.outcome != EntrySkipped,
    sol_plan.reason,
    if sol_plan.outcome == EntrySkipped do "skip" else "entry" end
  ) ?
  persist_risk_decision(
    pool,
    snapshot,
    jito_portfolio_id,
    jito_runtime,
    jito_plan.outcome != EntrySkipped,
    jito_plan.reason,
    if jito_plan.outcome == EntrySkipped do "skip" else "entry" end
  ) ?
  if sol_plan.outcome == EntrySkipped || jito_plan.outcome == EntrySkipped do
    return Ok(0)
  end

  let sol_entry = (sol_plan |5> entry_record(
    snapshot,
    result,
    sol_portfolio_id,
    sol_runtime
  )) ?
  let jito_entry = (jito_plan |5> entry_record(
    snapshot,
    result,
    jito_portfolio_id,
    jito_runtime
  )) ?
  let rows = Pool.query(pool, "SELECT apply_synchronized_paper_entries($1, $2, $3::jsonb, $4::jsonb)::text AS applied", [
    comparison_group_id,
    snapshot.event_id,
    sol_entry,
    jito_entry
  ]) ?
  if List.length(rows) != 1 do
    return Err("database returned invalid synchronized entry result")
  end
  if Map.get(List.head(rows), "applied") == "true" do
    Ok(2)
  else
    Err("synchronized comparison portfolio state changed")
  end
end

pub fn load_paper_position(pool :: PoolHandle, portfolio_id :: String) -> PaperPosition ! String do
  let rows = Pool.query(pool, "WITH balances AS (SELECT COALESCE(sum(CASE WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'BUY' THEN f.quantity_atoms::numeric WHEN ei.leg = 'SPOT' AND ei.intent_json->>'side' = 'SELL' THEN -f.quantity_atoms::numeric ELSE 0 END), 0)::text AS spot_quantity, COALESCE(sum(CASE WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'SELL' THEN f.quantity_atoms::numeric WHEN ei.leg = 'PERP' AND ei.intent_json->>'side' = 'BUY' THEN -f.quantity_atoms::numeric ELSE 0 END), 0)::text AS perp_short_quantity FROM fills f JOIN orders o ON o.id = f.order_id JOIN execution_intents ei ON ei.id = o.intent_id WHERE f.portfolio_run_id = $1), last_open AS (SELECT ne.observed_at_ms, CASE WHEN p.variant = 'sol_control' THEN '1000000000' ELSE od.nav_lamports END AS nav_lamports, CASE WHEN p.variant = 'sol_control' THEN '1000000000' ELSE trunc((ne.canonical_payload#>>'{payload,jitosolSpotBidPriceUsdMicros}')::numeric * 1000000000 / (ne.canonical_payload#>>'{payload,solPriceUsdMicros}')::numeric)::text END AS market_rate FROM fills f JOIN orders o ON o.id = f.order_id JOIN execution_intents ei ON ei.id = o.intent_id JOIN normalized_events ne ON ne.id = f.source_snapshot_id JOIN opportunity_decisions od ON od.source_event_id = ne.id AND od.variant = ei.variant JOIN portfolio_runs p ON p.id = f.portfolio_run_id WHERE f.portfolio_run_id = $1 AND ei.operation = 'OPEN' AND ei.leg = 'SPOT' ORDER BY ne.observed_at_ms DESC LIMIT 1), latest_position AS (SELECT observed_at_ms, protocol_nav_rate_atoms, market_sell_rate_atoms FROM position_snapshots WHERE portfolio_run_id = $1 ORDER BY observed_at_ms DESC LIMIT 1) SELECT p.variant::text, p.state_version::text, p.random_state::text, b.spot_quantity, b.perp_short_quantity, COALESCE(CASE WHEN COALESCE(lp.observed_at_ms, -1) >= COALESCE(lo.observed_at_ms, -1) THEN lp.protocol_nav_rate_atoms ELSE lo.nav_lamports END, '1') AS prior_nav, COALESCE(CASE WHEN COALESCE(lp.observed_at_ms, -1) >= COALESCE(lo.observed_at_ms, -1) THEN lp.market_sell_rate_atoms ELSE lo.market_rate END, '1') AS prior_market_rate FROM portfolio_runs p CROSS JOIN balances b LEFT JOIN last_open lo ON true LEFT JOIN latest_position lp ON true WHERE p.id = $1 AND p.state IN ('hedged', 'opening_spot', 'opening_perp', 'emergency_flatten')", [portfolio_id]) ?
  if List.length(rows) != 1 do
    return Err("paper position not found")
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
    RecoverPosition -> "CLOSE"
  end
end

fn direct_unstake_record(
  snapshot :: MarketSnapshot,
  position :: PaperPosition,
  plan :: PositionPlan
) -> String ! String do
  if position.variant != JitoSolCarry || plan.action != ExitPosition do
    return Ok(json { enabled : false })
  end
  let config = load_runtime_config() ?
  let process = (position.spot_quantity
    |> start_direct_unstake(
    plan.valuation.protocol_nav_lamports,
    snapshot.sol_price_usd_micros,
    position.perp_short_quantity,
    RatePpm { atoms : 0 },
    snapshot.epoch,
    RatePpm {
      atoms : config.direct_unstake_fee_ppm
    },
    UsdMicros {
      atoms : config.direct_unstake_chain_fees_usd_micros
    },
    0,
    UsdMicros {
      atoms : config.direct_unstake_hedge_cost_usd_micros
    },
    UsdMicros {
      atoms : config.direct_unstake_capital_delay_haircut_usd_micros
    },
    UsdMicros {
      atoms : config.direct_unstake_final_hedge_close_cost_usd_micros
    }
  )) ?
  let projection = process.projection
  Ok(json {
    enabled : true,
    state : "requested",
    requestedEpoch : "${process.requested_epoch}",
    availableEpoch : "${process.available_epoch}",
    jitosolQuantityAtoms : "${position.spot_quantity.atoms}",
    hedgeQuantityAtoms : "${position.perp_short_quantity.atoms}",
    protocolRedemptionLamports : "${projection.protocol_redemption_lamports.atoms}",
    withdrawalFeeLamports : "${projection.withdrawal_fee_lamports.atoms}",
    netRedemptionLamports : "${projection.net_redemption_lamports.atoms}",
    protocolRedemptionUsdMicros : "${projection.protocol_redemption_usd_micros.atoms}",
    withdrawalFeeUsdMicros : "${projection.withdrawal_fee_usd_micros.atoms}",
    cooldownFundingUsdMicros : "${projection.cooldown_funding_usd_micros.atoms}",
    chainFeesUsdMicros : "${projection.chain_fees_usd_micros.atoms}",
    hedgeCostUsdMicros : "${projection.hedge_cost_usd_micros.atoms}",
    capitalDelayHaircutUsdMicros : "${projection.capital_delay_haircut_usd_micros.atoms}",
    finalHedgeCloseCostUsdMicros : "${projection.final_hedge_close_cost_usd_micros.atoms}",
    netUsdMicros : "${projection.net_usd_micros.atoms}"
  })
end

fn position_record(
  snapshot :: MarketSnapshot,
  portfolio_id :: String,
  position :: PaperPosition,
  plan :: PositionPlan
) -> String ! String do
  let operation = position_operation(plan.action)
  let variant = position.variant |> variant_name
  let intent_base = "${snapshot.event_id}:${portfolio_id}:${variant}:${action_name(plan.action)}"
  let spot_intent = paper_intent(
    "${intent_base}:spot:intent",
    snapshot.event_id,
    portfolio_id,
    position.state_version,
    snapshot.observed_at_ms,
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
    end,
    plan.spot_fill.placed
  ) ?
  let perp_intent = paper_intent(
    "${intent_base}:perp:intent",
    snapshot.event_id,
    portfolio_id,
    position.state_version,
    snapshot.observed_at_ms,
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
    end,
    plan.perp_fill.placed
  ) ?
  let reward_usd = (plan.valuation.reward_sol_lamports
    |> lamports_to_usd(snapshot.sol_price_usd_micros, :toward_zero)) ?
  let basis_usd = (plan.valuation.basis_sol_lamports
    |> lamports_to_usd(snapshot.sol_price_usd_micros, :toward_zero)) ?
  Ok(json {
    portfolioRunId : portfolio_id,
    expectedStateVersion : "${position.state_version}",
    plan : json {
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
      perpFeeUsdAtoms : "${plan.perp_fill.fee_usd.atoms}",
      directUnstake : (plan |3> direct_unstake_record(snapshot, position)) ?
    },
    spotIntent : spot_intent,
    spotIntentHash : spot_intent |> Crypto.sha256,
    perpIntent : perp_intent,
    perpIntentHash : perp_intent |> Crypto.sha256
  })
end

pub fn persist_position_plan(pool :: PoolHandle,
snapshot :: MarketSnapshot,
portfolio_id :: String,
position :: PaperPosition,
runtime :: PaperRuntime,
risk_approved :: Bool,
plan :: PositionPlan) -> Int ! String do
  persist_risk_decision(
    pool,
    snapshot,
    portfolio_id,
    runtime,
    risk_approved,
    plan.reason,
    action_name(plan.action)
  ) ?
  let record = (plan |4> position_record(snapshot, portfolio_id, position)) ?
  let rows = Pool.query(pool, "SELECT CASE WHEN $3::boolean THEN apply_paper_recovery_plan($1::jsonb->>'portfolioRunId', ($1::jsonb->>'expectedStateVersion')::bigint, $2, $1::jsonb->'plan', ($1::jsonb->>'spotIntent')::jsonb, ($1::jsonb->>'spotIntentHash')::char(64), ($1::jsonb->>'perpIntent')::jsonb, ($1::jsonb->>'perpIntentHash')::char(64)) ELSE apply_paper_position_plan($1::jsonb->>'portfolioRunId', ($1::jsonb->>'expectedStateVersion')::bigint, $2, $1::jsonb->'plan', ($1::jsonb->>'spotIntent')::jsonb, ($1::jsonb->>'spotIntentHash')::char(64), ($1::jsonb->>'perpIntent')::jsonb, ($1::jsonb->>'perpIntentHash')::char(64)) END::text AS applied", [
    record,
    snapshot.event_id,
    bool_string(plan.action == RecoverPosition)
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

pub fn persist_synchronized_position_plans(
  pool :: PoolHandle,
  comparison_group_id :: String,
  snapshot :: MarketSnapshot,
  sol_portfolio_id :: String,
  sol_position :: PaperPosition,
  sol_runtime :: PaperRuntime,
  sol_risk_approved :: Bool,
  sol_plan :: PositionPlan,
  jito_portfolio_id :: String,
  jito_position :: PaperPosition,
  jito_runtime :: PaperRuntime,
  jito_risk_approved :: Bool,
  jito_plan :: PositionPlan
) -> Int ! String do
  persist_risk_decision(
    pool,
    snapshot,
    sol_portfolio_id,
    sol_runtime,
    sol_risk_approved,
    sol_plan.reason,
    action_name(sol_plan.action)
  ) ?
  persist_risk_decision(
    pool,
    snapshot,
    jito_portfolio_id,
    jito_runtime,
    jito_risk_approved,
    jito_plan.reason,
    action_name(jito_plan.action)
  ) ?
  let sol_record = (sol_plan |4> position_record(
    snapshot,
    sol_portfolio_id,
    sol_position
  )) ?
  let jito_record = (jito_plan |4> position_record(
    snapshot,
    jito_portfolio_id,
    jito_position
  )) ?
  let rows = Pool.query(pool, "SELECT apply_synchronized_paper_position_plans($1, $2, $3::jsonb, $4::jsonb)::text AS applied", [
    comparison_group_id,
    snapshot.event_id,
    sol_record,
    jito_record
  ]) ?
  if List.length(rows) != 1 do
    return Err("database returned invalid synchronized position result")
  end
  if Map.get(List.head(rows), "applied") == "true" do
    Ok(2)
  else
    Err("synchronized comparison portfolio state changed")
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

fn direct_unstake_funding_payments(
  rows,
  event :: FundingSettlement,
  index :: Int,
  payments :: List<String>
) -> List<String> ! String do
  if index >= List.length(rows) do
    Ok(payments)
  else
    let row = List.get(rows, index)
    let quantity = Lamports {
      atoms : required_int(
        Map.get(row, "hedge_quantity_atoms"),
        "direct unstake hedge quantity"
      ) ?
    }
    let amount = (quantity
      |> realized_funding_usd(
        event.sol_price_usd_micros,
        event.realized_short_rate_ppm
      )) ?
    direct_unstake_funding_payments(
      rows,
      event,
      index + 1,
      List.append(payments, json {
        counterfactualId : Map.get(row, "id"),
        positionQuantityAtoms : "${quantity.atoms}",
        amountUsdMicros : "${amount.atoms}"
      })
    )
  end
end

pub fn load_direct_unstake_funding_payments(
  pool :: PoolHandle,
  event :: FundingSettlement
) -> List<String> ! String do
  (Pool.query(pool, "SELECT id, hedge_quantity_atoms FROM direct_unstake_counterfactuals WHERE state NOT IN ('withdrawn', 'failed') ORDER BY id", []) ?
    |> direct_unstake_funding_payments(event, 0, List.new()))
end

pub fn advance_direct_unstakes(
  pool :: PoolHandle,
  source_event_id :: String,
  epoch :: Int,
  outcome :: String
) -> Int ! String do
  let rows = Pool.query(pool, "SELECT advance_direct_unstake_counterfactuals($1, $2::bigint, $3)::text AS applied", [
    source_event_id,
    "${epoch}",
    outcome
  ]) ?
  if List.length(rows) != 1 do
    Err("database returned invalid direct unstake advancement")
  else
    required_int(
      Map.get(List.head(rows), "applied"),
      "direct unstake advancement"
    )
  end
end

pub fn persist_funding_settlement(
  pool :: PoolHandle,
  body :: String,
  payments :: List<String>,
  counterfactual_payments :: List<String>
) -> FundingPersistence ! String do
  let rows = Pool.query(pool, "WITH applied AS (SELECT apply_funding_settlements($1::jsonb, $2::jsonb, $3::jsonb) AS result) SELECT result->>'insertedEvent' AS inserted_event, result->>'payments' AS payments, result->>'counterfactualPayments' AS counterfactual_payments FROM applied", [
    body,
    "[${String.join(payments, ",")}]",
    "[${String.join(counterfactual_payments, ",")}]"
  ]) ?
  if List.length(rows) != 1 do
    return Err("database returned invalid funding settlement result")
  end
  let row = List.head(rows)
  Ok(FundingPersistence {
    inserted_event : Map.get(row, "inserted_event") == "true",
    payments : required_int(Map.get(row, "payments"), "funding payment count") ?,
    counterfactual_payments : required_int(
      Map.get(row, "counterfactual_payments"),
      "direct unstake funding payment count"
    ) ?
  })
end

pub fn persist_operator_command(
  pool :: PoolHandle,
  action :: String,
  target :: String,
  idempotency_key :: String,
  reason :: String,
  request_hash :: String
) -> String ! String do
  let rows = Pool.query(pool, "SELECT apply_reconciled_operator_command($1, $2, $3, $4, $5)::text AS body", [
    action,
    target,
    idempotency_key,
    reason,
    request_hash
  ]) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid operator command result")
  else
    Ok(Map.get(List.head(rows), "body"))
  end
end

pub fn reconcile_paper_state(
  pool :: PoolHandle,
  reconciliation_id :: String,
  reason :: String
) -> String ! String do
  let rows = ("SELECT record_paper_reconciliation($1, $2)->>'result' AS result"
    |2> Pool.query(pool, [reconciliation_id, reason])) ?
  if List.length(rows) != 1 do
    Err("database returned an invalid paper reconciliation result")
  else
    Ok(Map.get(List.head(rows), "result"))
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

pub fn bootstrap_paper_runs(pool :: PoolHandle, code_commit :: String, mesh_commit :: String, config_hash :: String, target_notional :: Int) -> Int ! String do
  let existing = Pool.query(pool, "SELECT config_hash FROM strategy_runs WHERE id = 'local-paper-run'", []) ?
  if List.length(existing) > 1 || (
    List.length(existing) == 1
    && Map.get(List.head(existing), "config_hash") != config_hash
  ) do
    return Err("running paper strategy config does not match runtime fingerprint")
  end
  let applied = ("WITH build AS (INSERT INTO build_manifests (id, code_commit, mesh_commit, schema_version, config_hash) VALUES ('local-paper-build', $1, $2, 27, $3) ON CONFLICT (id) DO UPDATE SET code_commit = EXCLUDED.code_commit, mesh_commit = EXCLUDED.mesh_commit, schema_version = EXCLUDED.schema_version, config_hash = EXCLUDED.config_hash RETURNING id), run AS (INSERT INTO strategy_runs (id, execution_mode, config_hash, build_manifest_id, prng_seed, prng_version) SELECT 'local-paper-run', 'paper', $3, id, 42, 'xorshift64star-v1' FROM build ON CONFLICT (id) DO UPDATE SET config_hash = EXCLUDED.config_hash, build_manifest_id = EXCLUDED.build_manifest_id WHERE strategy_runs.config_hash = repeat('0', 64) RETURNING id), comparison AS (INSERT INTO comparison_groups (id, strategy_run_id, mode, target_notional_usd_micros, entry_policy_version, exit_policy_version) VALUES ('local-paper-run:independent', 'local-paper-run', 'independent', $4, 'paper-entry-v1', 'paper-exit-v1'), ('local-paper-run:synchronized', 'local-paper-run', 'synchronized', $4, 'paper-entry-v1', 'paper-exit-v1') ON CONFLICT (id) DO UPDATE SET mode = EXCLUDED.mode, target_notional_usd_micros = EXCLUDED.target_notional_usd_micros, entry_policy_version = EXCLUDED.entry_policy_version, exit_policy_version = EXCLUDED.exit_policy_version RETURNING id), portfolios AS (INSERT INTO portfolio_runs (id, strategy_run_id, comparison_group_id, variant, execution_mode, initial_capital_usd_micros) VALUES ('local-sol-control', 'local-paper-run', 'local-paper-run:independent', 'sol_control', 'paper', 1000000000), ('local-jitosol-carry', 'local-paper-run', 'local-paper-run:independent', 'jitosol_carry', 'paper', 1000000000), ('local-sync-sol-control', 'local-paper-run', 'local-paper-run:synchronized', 'sol_control', 'paper', 1000000000), ('local-sync-jitosol-carry', 'local-paper-run', 'local-paper-run:synchronized', 'jitosol_carry', 'paper', 1000000000) ON CONFLICT (id) DO UPDATE SET comparison_group_id = EXCLUDED.comparison_group_id RETURNING id), batches AS (INSERT INTO ledger_batches (id, portfolio_run_id, event_type, event_id, batch_hash) SELECT id || ':opening', id, 'opening_capital', id || ':opening', repeat('0', 64) FROM portfolios ON CONFLICT (id) DO NOTHING RETURNING id, portfolio_run_id) INSERT INTO ledger_entries (ledger_batch_id, account_debit, account_credit, asset, amount_atoms, usd_value_atoms) SELECT id, 'paper_cash', 'paper_equity', 'USDC', '1000000000', '1000000000' FROM batches" |2> Pool.execute(pool, [code_commit, mesh_commit, config_hash, "${target_notional}"])) ?
  let capability_rows = ("SELECT record_language_capability_results($1)::text AS count" |2> Pool.query(pool, ["local-paper-build"])) ?
  if List.length(capability_rows) != 1 || Map.get(List.head(capability_rows), "count") != "23" do
    return Err("database returned an invalid language capability result")
  end
  Ok(applied)
end
