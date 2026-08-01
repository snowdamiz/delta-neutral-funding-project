from Packages.Accounting import realized_funding_usd
from Packages.BuildIdentity import code_commit, mesh_commit
from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros
from Packages.LeaderLease import lease_held
from Packages.Log import info, warn
from Packages.Metrics import render
from Packages.Opportunity import OpportunitySet, evaluate_snapshot_for_horizon
from Packages.PaperEngine import PaperAction, PaperPosition, PaperRuntime, PaperVariant, PositionPlan, plan_controlled_entry, plan_controlled_position, plan_entry, plan_forced_exit, plan_position, plan_recovery, position_risk_approved
from Packages.ProtocolContracts import FundingObservation, FundingSettlement, MarketSnapshot, WalletObservation, parse_funding_observation, parse_funding_settlement, parse_market_snapshot, parse_shadow_result, parse_wallet_observation
from Packages.ReadModels import adapter_status, cross_venue_funding_leaderboard, fills, funding, funding_leaderboard, jitosol, latest_reconciliation, orders, pnl, pnl_comparison, portfolio, portfolios, positions, reverse_carry_leaderboard, risk_decisions, risk_events, shadow_results, strategies, wallet_config, wallet_tracking
from Packages.RuntimeConfig import load_runtime_config, runtime_config_hash
from Packages.SolanaWalletFlow import SolanaWalletFlowEvent, parse_solana_wallet_flow_event, persist_solana_wallet_flow_event, solana_wallet_flow_state
from Packages.StateMachine import PortfolioState
from Packages.Storage import FundingPersistence, PendingPaperAction, advance_direct_unstakes, list_opportunities, load_direct_unstake_funding_payments, load_paper_position, load_paper_runtime, load_pending_paper_action, persist_funding_observation, persist_funding_settlement, persist_operator_command, persist_opportunities, persist_paper_plan, persist_paper_reset, persist_position_plan, persist_shadow_result, persist_synchronized_paper_entries, persist_synchronized_position_plans, persist_wallet_config, persist_wallet_observation, run_cross_asset_paper_scan, run_cross_venue_paper_scan, run_nav_discount_paper_cycle, run_reverse_carry_paper_scan
from Runtime.Registry import get_pool, record_accepted, record_rejected

fn error_response(status :: Int, code :: String, message :: String) do
  HTTP.response(status, json { error : code, message : message })
end

pub struct Page do
  limit :: Int
  offset :: Int
end

fn query_integer(
  request :: Request,
  name :: String,
  fallback :: Int,
  maximum :: Int
) -> Int ! String do
  case Request.query(request, name) do
    None -> Ok(fallback)
    Some(raw) -> do
      case String.to_int(raw) do
        Some(value) -> do
          if value < 0 || value > maximum do
            Err("${name} must be between zero and ${maximum}")
          else
            Ok(value)
          end
        end
        None -> Err("${name} must be an integer")
      end
    end
  end
end

fn page(request :: Request) -> Page ! String do
  Ok(Page {
    limit : query_integer(request, "limit", 50, 100) ?,
    offset : query_integer(request, "offset", 0, 1000000) ?
  })
end

fn read_response(result) do
  case result do
    Ok(body) -> HTTP.response(200, body)
    Err(reason) -> error_response(500, "query_failed", reason)
  end
end

fn request_header(request :: Request, name :: String) -> String do
  case Request.header(request, name) do
    Some(value) -> value
    None -> ""
  end
end

fn request_signature(request :: Request) -> String do
  request_header(request, "x-adapter-signature")
end

fn authenticated(request :: Request, body :: String) -> Bool do
  let secret = Env.get("ADAPTER_HMAC_SECRET", "")
  if String.length(secret) == 0 do
    false
  else
    body
      |2> Crypto.hmac_sha256(secret)
      |2> Crypto.secure_compare(request_signature(request))
  end
end

fn operator_authenticated(
  request :: Request,
  idempotency_key :: String,
  body :: String
) -> Bool do
  let secret = Env.get("OPERATOR_HMAC_SECRET", "")
  if String.length(secret) == 0 || String.length(idempotency_key) == 0 do
    false
  else
    "${idempotency_key}\n${body}"
      |2> Crypto.hmac_sha256(secret)
      |2> Crypto.secure_compare(
        request_header(request, "x-operator-signature")
      )
  end
end

fn accepted_response(snapshot :: MarketSnapshot, result :: OpportunitySet, duplicate :: Bool) do
  HTTP.response(202, json {
    status : if duplicate do "duplicate" else "accepted" end,
    eventId : snapshot.event_id,
    navLamports : "${result.nav_lamports.atoms}",
    hedgeLamports : "${result.hedge_lamports.atoms}",
    expectedFundingUsdMicros : "${result.expected_funding_usd_micros.atoms}",
    navRewardUsdMicros : "${result.nav_reward_usd_micros.atoms}",
    solNetCarryUsdMicros : "${result.sol_net_carry_usd_micros.atoms}",
    jitosolNetCarryUsdMicros : "${result.jitosol_net_carry_usd_micros.atoms}",
    solEligible : result.sol_eligible,
    jitosolEligible : result.jitosol_eligible
  })
end

fn run_portfolio_cycle(pool :: PoolHandle,
snapshot :: MarketSnapshot,
result :: OpportunitySet,
portfolio_id :: String,
variant :: PaperVariant,
runtime :: PaperRuntime) -> Int ! String do
  if runtime.state == Idle do
    if runtime.pause_all do
      return Ok(0)
    end
    let plan = (runtime |4> plan_entry(snapshot, result, variant)) ?
    return plan |6> persist_paper_plan(pool, snapshot, result, portfolio_id, runtime)
  end
  if runtime.state == OpeningSpot || runtime.state == OpeningPerp || runtime.state == EmergencyFlatten do
    let position = (portfolio_id |2> load_paper_position(pool)) ?
    let plan = (runtime.state |4> plan_recovery(
      snapshot,
      result,
      position
    )) ?
    return plan |7> persist_position_plan(
      pool,
      snapshot,
      portfolio_id,
      position,
      runtime,
      false
    )
  end
  if runtime.state != Hedged do
    return Ok(0)
  end
  let position = (portfolio_id |2> load_paper_position(pool)) ?
  case (portfolio_id |2> load_pending_paper_action(pool)) ? do
    PendingAction(action, reason) -> do
      let plan = plan_forced_exit(
        snapshot,
        result,
        position,
        action <> ":" <> reason
      ) ?
      plan |7> persist_position_plan(
        pool,
        snapshot,
        portfolio_id,
        position,
        runtime,
        true
      )
    end
    NoPendingAction -> do
      if runtime.pause_all do
        return Ok(0)
      end
      let plan = (runtime |4> plan_position(
        snapshot,
        result,
        position
      )) ?
      plan |7> persist_position_plan(
        pool,
        snapshot,
        portfolio_id,
        position,
        runtime,
        position_risk_approved(plan)
      )
    end
  end
end

fn paper_runtime(pool :: PoolHandle, portfolio_id :: String, now_ms :: Int) -> PaperRuntime ! String do
  let config = load_runtime_config() ?
  portfolio_id |2> load_paper_runtime(
    pool,
    now_ms,
    config.max_source_age_ms,
    config.minimum_margin_ratio_ppm,
    config.minimum_liquidation_distance_bps,
    config.rebalance_delta_bps
  )
end

fn run_independent_pair(
  pool :: PoolHandle,
  snapshot :: MarketSnapshot,
  result :: OpportunitySet,
  now_ms :: Int
) -> Int ! String do
  run_portfolio_cycle(
    pool,
    snapshot,
    result,
    "local-sol-control",
    SolControl,
    ("local-sol-control" |2> paper_runtime(pool, now_ms)) ?
  ) ?
  run_portfolio_cycle(
    pool,
    snapshot,
    result,
    "local-jitosol-carry",
    JitoSolCarry,
    ("local-jitosol-carry" |2> paper_runtime(pool, now_ms)) ?
  )
end

fn requires_controlled_exit(action :: PaperAction) -> Bool do
  action == ExitPosition || action == EmergencyPosition
end

fn controlled_pending_reason(pool :: PoolHandle) -> String ! String do
  case ("local-sync-sol-control" |2> load_pending_paper_action(pool)) ? do
    PendingAction(action, reason) -> Ok(action <> ":" <> reason)
    NoPendingAction -> case ("local-sync-jitosol-carry" |2> load_pending_paper_action(pool)) ? do
      PendingAction(action, reason) -> Ok(action <> ":" <> reason)
      NoPendingAction -> Ok("")
    end
  end
end

fn persist_controlled_positions(
  pool :: PoolHandle,
  snapshot :: MarketSnapshot,
  sol_position :: PaperPosition,
  sol_runtime :: PaperRuntime,
  sol_risk_approved :: Bool,
  sol_plan :: PositionPlan,
  jito_position :: PaperPosition,
  jito_runtime :: PaperRuntime,
  jito_risk_approved :: Bool,
  jito_plan :: PositionPlan
) -> Int ! String do
  persist_synchronized_position_plans(
    pool,
    "local-paper-run:synchronized",
    snapshot,
    "local-sync-sol-control",
    sol_position,
    sol_runtime,
    sol_risk_approved,
    sol_plan,
    "local-sync-jitosol-carry",
    jito_position,
    jito_runtime,
    jito_risk_approved,
    jito_plan
  )
end

fn force_controlled_exit(
  pool :: PoolHandle,
  snapshot :: MarketSnapshot,
  result :: OpportunitySet,
  sol_position :: PaperPosition,
  sol_runtime :: PaperRuntime,
  jito_position :: PaperPosition,
  jito_runtime :: PaperRuntime,
  reason :: String,
  risk_approved :: Bool
) -> Int ! String do
  let sol_plan = (reason |4> plan_forced_exit(
    snapshot,
    result,
    sol_position
  )) ?
  let jito_plan = (reason |4> plan_forced_exit(
    snapshot,
    result,
    jito_position
  )) ?
  persist_controlled_positions(
    pool,
    snapshot,
    sol_position,
    sol_runtime,
    risk_approved,
    sol_plan,
    jito_position,
    jito_runtime,
    risk_approved,
    jito_plan
  )
end

fn run_synchronized_positions(
  pool :: PoolHandle,
  snapshot :: MarketSnapshot,
  result :: OpportunitySet,
  sol_runtime :: PaperRuntime,
  jito_runtime :: PaperRuntime
) -> Int ! String do
  let sol_position = ("local-sync-sol-control" |2> load_paper_position(pool)) ?
  let jito_position = ("local-sync-jitosol-carry" |2> load_paper_position(pool)) ?
  let pending_reason = controlled_pending_reason(pool) ?
  if String.length(pending_reason) > 0 do
    return force_controlled_exit(
      pool,
      snapshot,
      result,
      sol_position,
      sol_runtime,
      jito_position,
      jito_runtime,
      pending_reason,
      true
    )
  end
  if sol_runtime.pause_all || jito_runtime.pause_all do
    return Ok(0)
  end
  let sol_plan = (sol_runtime |4> plan_controlled_position(
    snapshot,
    result,
    sol_position
  )) ?
  let jito_plan = (jito_runtime |4> plan_controlled_position(
    snapshot,
    result,
    jito_position
  )) ?
  if requires_controlled_exit(sol_plan.action) do
    return force_controlled_exit(
      pool,
      snapshot,
      result,
      sol_position,
      sol_runtime,
      jito_position,
      jito_runtime,
      "controlled_exit:" <> sol_plan.reason,
      false
    )
  end
  if requires_controlled_exit(jito_plan.action) do
    return force_controlled_exit(
      pool,
      snapshot,
      result,
      sol_position,
      sol_runtime,
      jito_position,
      jito_runtime,
      "controlled_exit:" <> jito_plan.reason,
      false
    )
  end
  persist_controlled_positions(
    pool,
    snapshot,
    sol_position,
    sol_runtime,
    position_risk_approved(sol_plan),
    sol_plan,
    jito_position,
    jito_runtime,
    position_risk_approved(jito_plan),
    jito_plan
  )
end

fn recover_controlled_member(
  pool :: PoolHandle,
  snapshot :: MarketSnapshot,
  result :: OpportunitySet,
  portfolio_id :: String,
  runtime :: PaperRuntime
) -> Int ! String do
  if runtime.state == Idle do
    return Ok(0)
  end
  let position = (portfolio_id |2> load_paper_position(pool)) ?
  if runtime.state == OpeningSpot || runtime.state == OpeningPerp || runtime.state == EmergencyFlatten do
    let plan = (runtime.state |4> plan_recovery(
      snapshot,
      result,
      position
    )) ?
    return plan |7> persist_position_plan(
      pool,
      snapshot,
      portfolio_id,
      position,
      runtime,
      false
    )
  end
  if runtime.state == Hedged do
    let plan = ("controlled_peer_recovery" |4> plan_forced_exit(
      snapshot,
      result,
      position
    )) ?
    return plan |7> persist_position_plan(
      pool,
      snapshot,
      portfolio_id,
      position,
      runtime,
      true
    )
  end
  Ok(0)
end

fn run_synchronized_pair(
  pool :: PoolHandle,
  snapshot :: MarketSnapshot,
  result :: OpportunitySet,
  now_ms :: Int
) -> Int ! String do
  let sol_runtime = ("local-sync-sol-control" |2> paper_runtime(pool, now_ms)) ?
  let jito_runtime = ("local-sync-jitosol-carry" |2> paper_runtime(pool, now_ms)) ?
  if sol_runtime.state == Idle && jito_runtime.state == Idle do
    let sol_plan = (sol_runtime |4> plan_controlled_entry(snapshot, result, SolControl)) ?
    let jito_plan = (jito_runtime |4> plan_controlled_entry(snapshot, result, JitoSolCarry)) ?
    return persist_synchronized_paper_entries(
      pool,
      "local-paper-run:synchronized",
      snapshot,
      result,
      "local-sync-sol-control",
      sol_runtime,
      sol_plan,
      "local-sync-jitosol-carry",
      jito_runtime,
      jito_plan
    )
  end
  if sol_runtime.state == Hedged && jito_runtime.state == Hedged do
    return run_synchronized_positions(
      pool,
      snapshot,
      result,
      sol_runtime,
      jito_runtime
    )
  end
  let sol_applied = (sol_runtime |5> recover_controlled_member(
    pool,
    snapshot,
    result,
    "local-sync-sol-control"
  )) ?
  let jito_applied = (jito_runtime |5> recover_controlled_member(
    pool,
    snapshot,
    result,
    "local-sync-jitosol-carry"
  )) ?
  sol_applied |> Checked.add(jito_applied)
end

fn run_paper_cycle(body :: String, snapshot :: MarketSnapshot, result :: OpportunitySet) -> Int ! String do
  let pool = get_pool()
  let config = load_runtime_config() ?
  let inserted = (config
    |> runtime_config_hash
    |5> persist_opportunities(pool, body, snapshot, result)) ?
  (snapshot.event_id |2> advance_direct_unstakes(
    pool,
    snapshot.epoch,
    config.direct_unstake_scenario
  )) ?
  let now_ms = DateTime.utc_now() |> DateTime.to_unix_ms
  let nav_result = run_nav_discount_paper_cycle(
    pool,
    snapshot.event_id,
    now_ms,
    config.max_source_age_ms,
    config.minimum_margin_ratio_ppm,
    config.minimum_liquidation_distance_bps,
    config.direct_unstake_fee_ppm,
    config.direct_unstake_chain_fees_usd_micros,
    config.direct_unstake_hedge_cost_usd_micros,
    config.direct_unstake_capital_delay_haircut_usd_micros,
    config.direct_unstake_final_hedge_close_cost_usd_micros,
    config.expected_hold_hours
  ) ?
  info("nav_discount_paper_cycle", nav_result)
  (now_ms |4> run_independent_pair(pool, snapshot, result)) ?
  (now_ms |4> run_synchronized_pair(pool, snapshot, result)) ?
  Ok(inserted)
end

fn persist_response(body :: String, snapshot :: MarketSnapshot, result :: OpportunitySet) do
  case run_paper_cycle(body, snapshot, result) do
    Ok(inserted) -> do
      record_accepted()
      info("protocol_event_accepted", "{\"eventId\":\"${snapshot.event_id}\",\"inserted\":\"${inserted}\"}")
      accepted_response(snapshot, result, inserted == 0)
    end
    Err(reason) -> do
      record_rejected()
      if String.contains(reason, "source sequence gap or regression") do
        error_response(409, "source_gap", "source continuity lost; resnapshot required")
      else
        error_response(500, "persistence_failed", reason)
      end
    end
  end
end

fn evaluate_response(body :: String, snapshot :: MarketSnapshot) do
  case load_runtime_config() do
    Ok(config) -> case evaluate_snapshot_for_horizon(
      snapshot,
      config.expected_hold_hours,
      config.maximum_break_even_hours
    ) do
      Ok(result) -> persist_response(body, snapshot, result)
      Err(reason) -> do
        record_rejected()
        error_response(422, "evaluation_failed", reason)
      end
    end
    Err(reason) -> error_response(503, "config_unavailable", reason)
  end
end

fn funding_payment(
  pool :: PoolHandle,
  portfolio_id :: String,
  event :: FundingSettlement,
  now_ms :: Int
) -> String ! String do
  let runtime = (portfolio_id |2> paper_runtime(pool, now_ms)) ?
  if runtime.state != Hedged do
    Ok(json { enabled : false })
  else
    let position = (portfolio_id |2> load_paper_position(pool)) ?
    let amount = (position.perp_short_quantity
      |> realized_funding_usd(
        event.sol_price_usd_micros,
        event.realized_short_rate_ppm
      )) ?
    Ok(json {
      enabled : true,
      portfolioRunId : portfolio_id,
      stateVersion : "${position.state_version}",
      positionQuantityAtoms : "${position.perp_short_quantity.atoms}",
      amountUsdMicros : "${amount.atoms}"
    })
  end
end

fn funding_accepted_response(event :: FundingSettlement, result :: FundingPersistence) do
  HTTP.response(202, json {
    status : if result.inserted_event do "accepted" else "duplicate" end,
    eventId : event.event_id,
    payments : result.payments,
    counterfactualPayments : result.counterfactual_payments
  })
end

fn funding_payments(
  pool :: PoolHandle,
  event :: FundingSettlement,
  now_ms :: Int,
  portfolio_ids :: List<String>,
  index :: Int,
  payments :: List<String>
) -> List<String> ! String do
  if index >= List.length(portfolio_ids) do
    Ok(payments)
  else
    let payment = (List.get(portfolio_ids, index)
      |2> funding_payment(pool, event, now_ms)) ?
    funding_payments(
      pool,
      event,
      now_ms,
      portfolio_ids,
      index + 1,
      List.append(payments, payment)
    )
  end
end

fn funding_response(body :: String, event :: FundingSettlement) do
  let pool = get_pool()
  let now_ms = DateTime.utc_now() |> DateTime.to_unix_ms
  case funding_payments(
    pool,
    event,
    now_ms,
    [
      "local-sol-control",
      "local-jitosol-carry",
      "local-sync-sol-control",
      "local-sync-jitosol-carry"
    ],
    0,
    List.new()
  ) do
    Ok(payments) -> case (event |2> load_direct_unstake_funding_payments(pool)) do
      Ok(counterfactual_payments) -> case persist_funding_settlement(
        pool,
        body,
        payments,
        counterfactual_payments
      ) do
        Ok(result) -> do
          record_accepted()
          info("funding_event_accepted", "{\"eventId\":\"${event.event_id}\",\"payments\":\"${result.payments}\",\"counterfactualPayments\":\"${result.counterfactual_payments}\"}")
          funding_accepted_response(event, result)
        end
        Err(reason) -> do
          record_rejected()
          error_response(500, "persistence_failed", reason)
        end
      end
      Err(reason) -> do
        record_rejected()
        error_response(500, "funding_evaluation_failed", reason)
      end
    end
    Err(reason) -> do
      record_rejected()
      error_response(500, "funding_evaluation_failed", reason)
    end
  end
end

fn funding_observation_response(event :: FundingObservation) do
  case load_runtime_config() do
    Ok(config) -> case persist_funding_observation(
      get_pool(),
      event,
      config.source_max_funding_age_ms,
      config.source_max_borrow_age_ms
    ) do
      Ok(result) -> do
        let cross_result = if result.scan_complete do
          run_cross_asset_paper_scan(
            get_pool(),
            event.scan_id,
            event.observed_at_ms,
            config.source_max_funding_age_ms,
            config.target_notional_usd_micros,
            config.paper_costs_usd_micros,
            config.paper_risk_haircut_usd_micros,
            config.expected_hold_hours
          )
        else
          Ok("{\"status\":\"scan_incomplete\"}")
        end
        case cross_result do
          Err(reason) -> do
            record_rejected()
            return error_response(500, "paper_cycle_failed", reason)
          end
          Ok(body) -> if result.scan_complete do
            info("cross_asset_paper_cycle", body)
          else
            ()
          end
        end
        let reverse_result = if result.scan_complete do
          run_reverse_carry_paper_scan(
            get_pool(),
            event.scan_id,
            event.observed_at_ms,
            config.source_max_funding_age_ms,
            config.source_max_borrow_age_ms,
            config.target_notional_usd_micros,
            config.paper_costs_usd_micros,
            config.paper_risk_haircut_usd_micros,
            config.expected_hold_hours,
            config.maximum_break_even_hours,
            config.reverse_minimum_negative_funding_ppm,
            config.reverse_maximum_borrow_utilization_ppm
          )
        else
          Ok("{\"status\":\"scan_incomplete\"}")
        end
        case reverse_result do
          Err(reason) -> do
            record_rejected()
            return error_response(500, "paper_cycle_failed", reason)
          end
          Ok(body) -> if result.scan_complete do
            info("reverse_carry_paper_cycle", body)
          else
            ()
          end
        end
        let venue_result = if result.scan_complete do
          run_cross_venue_paper_scan(
            get_pool(),
            event.scan_id,
            event.observed_at_ms,
            config.source_max_funding_age_ms,
            config.target_notional_usd_micros,
            config.paper_costs_usd_micros,
            config.paper_risk_haircut_usd_micros,
            config.expected_hold_hours,
            config.paper_collateral_usd_micros,
            config.minimum_margin_ratio_ppm,
            config.minimum_liquidation_distance_bps
          )
        else
          Ok("{\"status\":\"scan_incomplete\"}")
        end
        case venue_result do
          Err(reason) -> do
            record_rejected()
            return error_response(500, "paper_cycle_failed", reason)
          end
          Ok(body) -> if result.scan_complete do
            info("cross_venue_paper_cycle", body)
          else
            ()
          end
        end
        record_accepted()
        info("funding_observation_accepted", "{\"eventId\":\"${event.event_id}\",\"venue\":\"${event.venue}\",\"asset\":\"${event.asset}\",\"scanComplete\":\"${result.scan_complete}\"}")
        HTTP.response(202, json {
          status : if result.inserted do "accepted" else "duplicate" end,
          eventId : event.event_id,
          scanId : event.scan_id,
          scanComplete : result.scan_complete
        })
      end
      Err(reason) -> do
        record_rejected()
        error_response(500, "persistence_failed", reason)
      end
    end
    Err(reason) -> error_response(503, "config_unavailable", reason)
  end
end

fn wallet_observation_response(event :: WalletObservation) do
  case load_runtime_config() do
    Ok(config) -> case persist_wallet_observation(
      get_pool(),
      event,
      config.source_max_funding_age_ms,
      config.target_notional_usd_micros,
      config.paper_costs_usd_micros
    ) do
      Ok(body) -> do
        record_accepted()
        info(
          "wallet_observation_accepted",
          "{\"eventId\":\"${event.event_id}\",\"wallet\":\"${event.wallet}\",\"positions\":\"${event.positions}\",\"fills\":\"${event.fills}\"}"
        )
        HTTP.response(202, body)
      end
      Err(reason) -> do
        record_rejected()
        error_response(500, "persistence_failed", reason)
      end
    end
    Err(reason) -> error_response(503, "config_unavailable", reason)
  end
end

fn solana_wallet_flow_response(event :: SolanaWalletFlowEvent) do
  case persist_solana_wallet_flow_event(get_pool(), event) do
    Ok(body) -> do
      record_accepted()
      info(
        "solana_wallet_flow_event_accepted",
        "{\"eventId\":\"${event.event_id}\",\"eventType\":\"${event.event_type}\",\"wallet\":\"${event.wallet}\"}"
      )
      HTTP.response(202, body)
    end
    Err(reason) -> do
      record_rejected()
      error_response(500, "persistence_failed", reason)
    end
  end
end

fn authenticated_event_response(body :: String) do
  case Json.parse(body) do
    Ok(_parsed) -> do
      case Json.get(body, "eventType") do
        "MarketSnapshot" -> do
          case parse_market_snapshot(body) do
            Ok(snapshot) -> evaluate_response(body, snapshot)
            Err(reason) -> do
              record_rejected()
              error_response(400, "invalid_event", reason)
            end
          end
        end
        "FundingSettlement" -> do
          case parse_funding_settlement(body) do
            Ok(event) -> funding_response(body, event)
            Err(reason) -> do
              record_rejected()
              error_response(400, "invalid_event", reason)
            end
          end
        end
        "FundingObservation" -> do
          case parse_funding_observation(body) do
            Ok(event) -> funding_observation_response(event)
            Err(reason) -> do
              record_rejected()
              error_response(400, "invalid_event", reason)
            end
          end
        end
        "WalletObservation" -> do
          case parse_wallet_observation(body) do
            Ok(event) -> wallet_observation_response(event)
            Err(reason) -> do
              record_rejected()
              error_response(400, "invalid_event", reason)
            end
          end
        end
        "SolanaWalletAcquisition" -> do
          case parse_solana_wallet_flow_event(body) do
            Ok(event) -> solana_wallet_flow_response(event)
            Err(reason) -> do
              record_rejected()
              error_response(400, "invalid_event", reason)
            end
          end
        end
        "SolanaWalletCheckpoint" -> do
          case parse_solana_wallet_flow_event(body) do
            Ok(event) -> solana_wallet_flow_response(event)
            Err(reason) -> do
              record_rejected()
              error_response(400, "invalid_event", reason)
            end
          end
        end
        "SolanaCandidateSnapshot" -> do
          case parse_solana_wallet_flow_event(body) do
            Ok(event) -> solana_wallet_flow_response(event)
            Err(reason) -> do
              record_rejected()
              error_response(400, "invalid_event", reason)
            end
          end
        end
        _ -> do
          record_rejected()
          error_response(400, "invalid_event", "unsupported event type")
        end
      end
    end
    Err(reason) -> do
      record_rejected()
      error_response(400, "invalid_event", reason)
    end
  end
end

fn operator_response(request :: Request, action :: String, target :: String) do
  let body = Request.body(request)
  let idempotency_key = request_header(request, "x-idempotency-key")
  if operator_authenticated(request, idempotency_key, body) == false do
    warn("operator_command_rejected", "{\"action\":\"${action}\",\"reason\":\"authentication\"}")
    return error_response(401, "unauthorized", "invalid operator signature")
  end
  if Regex.is_match(~r/^[A-Za-z0-9:_-]{1,200}$/, idempotency_key) == false do
    return error_response(400, "invalid_request", "invalid idempotency key")
  end
  if action == "resume" do
    case lease_held(get_pool()) do
      Ok(true) -> ()
      Ok(false) -> do
        return error_response(409, "leader_required", "cannot resume without the writer lease")
      end
      Err(reason) -> do
        return error_response(503, "lease_unavailable", reason)
      end
    end
  end
  case Json.parse(body) do
    Err(reason) -> error_response(400, "invalid_request", reason)
    Ok(_parsed) -> do
      if Json.is_string(body, "reason") == false do
        return error_response(400, "invalid_request", "reason must be a JSON string")
      end
      let reason = String.trim(Json.get(body, "reason"))
      if String.length(reason) == 0 || String.length(reason) > 500 do
        return error_response(400, "invalid_request", "reason must contain between 1 and 500 characters")
      end
      case ("${idempotency_key}\n${body}"
        |> Crypto.sha256
        |6> persist_operator_command(
          get_pool(),
          action,
          target,
          idempotency_key,
          reason
        )) do
        Ok(result) -> do
          info("operator_command_applied", "{\"action\":\"${action}\",\"idempotencyKey\":\"${idempotency_key}\"}")
          HTTP.response(202, result)
        end
        Err(error) -> do
          if String.contains(error, "idempotency key reused") do
            error_response(409, "idempotency_conflict", "idempotency key reused for a different command")
          else
            error_response(500, "operator_command_failed", error)
          end
        end
      end
    end
  end
end

fn wallet_config_values(body :: String) -> String ! String do
  let root = Json.parse(body) ?
  let wallets = (root |> Json.object_get("wallets")) ?
  let count = (wallets |> Json.array_length()) ?
  if count > 50 do
    Err("wallets must contain at most 50 addresses")
  else
    Ok(wallets |> Json.encode)
  end
end

fn wallet_config_response(request :: Request) do
  let body = Request.body(request)
  let idempotency_key = request_header(request, "x-idempotency-key")
  if operator_authenticated(request, idempotency_key, body) == false do
    warn("operator_command_rejected", "{\"action\":\"wallet_config\",\"reason\":\"authentication\"}")
    return error_response(401, "unauthorized", "invalid operator signature")
  end
  if Regex.is_match(~r/^[A-Za-z0-9:_-]{1,200}$/, idempotency_key) == false do
    return error_response(400, "invalid_request", "invalid idempotency key")
  end
  case lease_held(get_pool()) do
    Ok(true) -> ()
    Ok(false) -> do
      return error_response(409, "leader_required", "cannot configure wallets without the writer lease")
    end
    Err(reason) -> do
      return error_response(503, "lease_unavailable", reason)
    end
  end
  case wallet_config_values(body) do
    Err(reason) -> error_response(400, "invalid_wallet_config", reason)
    Ok(wallets_json) -> do
      if Json.is_string(body, "reason") == false do
        return error_response(400, "invalid_request", "reason must be a JSON string")
      end
      let reason = String.trim(Json.get(body, "reason"))
      if String.length(reason) == 0 || String.length(reason) > 500 do
        return error_response(400, "invalid_request", "reason must contain between 1 and 500 characters")
      end
      let request_hash = "${idempotency_key}\n${body}" |> Crypto.sha256
      case persist_wallet_config(
        get_pool(),
        idempotency_key,
        reason,
        request_hash,
        wallets_json
      ) do
        Ok(result) -> do
          info("operator_command_applied", "{\"action\":\"wallet_config\",\"idempotencyKey\":\"${idempotency_key}\"}")
          HTTP.response(202, result)
        end
        Err(error) -> do
          if String.contains(error, "idempotency key reused") do
            error_response(409, "idempotency_conflict", "idempotency key reused for a different command")
          else if String.contains(error, "wallet") do
            error_response(400, "invalid_wallet_config", error)
          else
            error_response(500, "operator_command_failed", error)
          end
        end
      end
    end
  end
end

fn positive_json_integer(body :: String, name :: String) -> Int ! String do
  if Json.is_string(body, name) == false do
    return Err("${name} must be a JSON string")
  end
  let raw = Json.get(body, name)
  if Regex.is_match(~r/^[1-9][0-9]{0,14}$/, raw) == false do
    return Err("${name} must be a canonical positive integer")
  end
  case (raw
    |> String.to_int) do
    Some(value) -> Ok(value)
    None -> Err("${name} must be a canonical integer")
  end
end

fn paper_reset_approval_expiry(body :: String) -> Int ! String do
  let expires_at_ms = positive_json_integer(body, "approvalExpiresAtMs") ?
  let now_ms = DateTime.utc_now()
    |> DateTime.to_unix_ms
  if expires_at_ms < now_ms || expires_at_ms > now_ms + 60000 do
    Err("paper reset approval is expired or too far in the future")
  else
    Ok(expires_at_ms)
  end
end

fn paper_reset_response(request :: Request) do
  let body = Request.body(request)
  let idempotency_key = request_header(request, "x-idempotency-key")
  if operator_authenticated(request, idempotency_key, body) == false do
    warn("operator_command_rejected", "{\"action\":\"paper_reset\",\"reason\":\"authentication\"}")
    return error_response(401, "unauthorized", "invalid operator signature")
  end
  if Regex.is_match(~r/^[A-Za-z0-9:_-]{1,200}$/, idempotency_key) == false do
    return error_response(400, "invalid_request", "invalid idempotency key")
  end
  case lease_held(get_pool()) do
    Ok(true) -> ()
    Ok(false) -> do
      return error_response(409, "leader_required", "cannot reset without the writer lease")
    end
    Err(reason) -> do
      return error_response(503, "lease_unavailable", reason)
    end
  end
  case Json.parse(body) do
    Err(reason) -> error_response(400, "invalid_request", reason)
    Ok(_parsed) -> do
      if Json.is_string(body, "reason") == false do
        return error_response(400, "invalid_request", "reason must be a JSON string")
      end
      let reason = String.trim(Json.get(body, "reason"))
      if String.length(reason) == 0 || String.length(reason) > 500 do
        return error_response(400, "invalid_request", "reason must contain between 1 and 500 characters")
      end
      let approved = Json.is_string(body, "approval") && Json.get(body, "approval") == "RESET PAPER"
      if approved == false do
        return error_response(400, "approval_required", "paper reset requires RESET PAPER approval")
      end
      case paper_reset_approval_expiry(body) do
        Err(reason) -> error_response(400, "approval_required", reason)
        Ok(approval_expires_at_ms) -> case positive_json_integer(
          body,
          "initialUsdcMicros"
        ) do
          Err(reason) -> error_response(400, "invalid_request", reason)
          Ok(initial_usdc_micros) -> case positive_json_integer(
            body,
            "initialCollateralUsdMicros"
          ) do
            Err(reason) -> error_response(400, "invalid_request", reason)
            Ok(initial_collateral_usd_micros) -> case load_runtime_config() do
              Err(reason) -> error_response(503, "config_unavailable", reason)
              Ok(config) -> do
                if initial_collateral_usd_micros != config.paper_collateral_usd_micros do
                  return error_response(409, "config_mismatch", "initial collateral must match the pinned paper configuration")
                end
                case ("${idempotency_key}\n${body}"
                  |> Crypto.sha256
                  |7> persist_paper_reset(
                    get_pool(),
                    initial_usdc_micros,
                    initial_collateral_usd_micros,
                    approval_expires_at_ms,
                    idempotency_key,
                    reason
                  )) do
                  Ok(result) -> do
                    info("operator_command_applied", "{\"action\":\"paper_reset\",\"idempotencyKey\":\"${idempotency_key}\"}")
                    HTTP.response(202, result)
                  end
                  Err(error) -> do
                    if String.contains(error, "idempotency key reused") do
                      error_response(409, "idempotency_conflict", "idempotency key reused for a different command")
                    else if String.contains(error, "requires") || String.contains(error, "reconciliation failed") do
                      error_response(409, "reset_precondition_failed", error)
                    else
                      error_response(500, "operator_command_failed", error)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

pub fn handle_event(request :: Request) -> Response do
  let body = Request.body(request)
  if authenticated(request, body) == false do
    record_rejected()
    warn("protocol_event_rejected", "{\"reason\":\"authentication\"}")
    error_response(401, "unauthorized", "invalid adapter signature")
  else
    case lease_held(get_pool()) do
      Ok(true) -> authenticated_event_response(body)
      Ok(false) -> error_response(503, "leader_required", "collector does not hold the writer lease")
      Err(reason) -> error_response(503, "lease_unavailable", reason)
    end
  end
end

pub fn handle_pause_entries(request :: Request) -> Response do
  operator_response(request, "pause_entries", "")
end

pub fn handle_pause_all(request :: Request) -> Response do
  operator_response(request, "pause_all", "")
end

pub fn handle_resume(request :: Request) -> Response do
  operator_response(request, "resume", "")
end

pub fn handle_reconcile(request :: Request) -> Response do
  operator_response(request, "reconcile", "")
end

pub fn handle_portfolio_exit(request :: Request) -> Response do
  case Request.param(request, "portfolio") do
    Some(portfolio_id) -> do
      if List.contains([
        "local-sol-control",
        "local-jitosol-carry",
        "local-sync-sol-control",
        "local-sync-jitosol-carry"
      ], portfolio_id) == false do
        return error_response(404, "not_found", "paper portfolio not found")
      end
      operator_response(request, "exit_position", portfolio_id)
    end
    None -> error_response(400, "invalid_request", "missing portfolio")
  end
end

pub fn handle_emergency_flatten(request :: Request) -> Response do
  operator_response(request, "emergency_flatten", "*")
end

pub fn handle_alerts_test(request :: Request) -> Response do
  operator_response(request, "alerts_test", "")
end

pub fn handle_paper_reset(request :: Request) -> Response do
  paper_reset_response(request)
end

pub fn handle_health(_request :: Request) -> Response do
  case ("SELECT 1 AS ok" |2> Pool.query(get_pool(), [])) do
    Ok(_rows) -> do
      case lease_held(get_pool()) do
        Ok(true) -> HTTP.response(200, json { status : "ok", database : "ok", leader : true, mode : "paper" })
        Ok(false) -> error_response(503, "not_leader", "collector does not hold the writer lease")
        Err(reason) -> error_response(503, "lease_unavailable", reason)
      end
    end
    Err(reason) -> error_response(503, "database_unavailable", reason)
  end
end

pub fn handle_build(_request :: Request) -> Response do
  case load_runtime_config() do
    Ok(config) -> HTTP.response(200, json {
      codeCommit : code_commit(),
      meshCommit : mesh_commit(),
      configHash : config |> runtime_config_hash,
      schemaVersion : 45
    })
    Err(reason) -> error_response(503, "config_unavailable", reason)
  end
end

pub fn handle_capabilities(_request :: Request) -> Response do
  case Pool.query(get_pool(), "SELECT jsonb_build_object('schemaVersion', 1, 'buildManifestId', build_manifest_id, 'results', jsonb_agg(jsonb_build_object('id', capability_id, 'status', status, 'evidence', evidence) ORDER BY capability_id))::text AS body FROM language_capability_results WHERE build_manifest_id = 'local-paper-build' GROUP BY build_manifest_id", []) do
    Ok(rows) -> do
      if List.length(rows) == 1 do
        HTTP.response(200, Map.get(List.head(rows), "body"))
      else
        error_response(503, "capabilities_unavailable", "build capability evidence is missing")
      end
    end
    Err(reason) -> error_response(500, "query_failed", reason)
  end
end

pub fn handle_status(_request :: Request) -> Response do
  case Pool.query(get_pool(), "SELECT c.pause_entries::text, c.pause_all::text, c.reason, c.version::text, COALESCE((SELECT holder_instance_id FROM leader_leases WHERE lease_name = 'collector'), '') AS leader_holder, COALESCE((SELECT generation::text FROM leader_leases WHERE lease_name = 'collector'), '0') AS leader_generation, (SELECT count(*)::text FROM portfolio_runs WHERE strategy_run_id = 'local-paper-run' AND state NOT IN ('idle', 'paused')) AS active_portfolios, COALESCE((SELECT sum(g.target_notional_usd_micros)::text FROM portfolio_runs p JOIN comparison_groups g ON g.id = p.comparison_group_id WHERE p.strategy_run_id = 'local-paper-run' AND p.state NOT IN ('idle', 'paused')), '0') AS live_notional FROM control_state c", []) do
    Ok(rows) -> do
      let row = List.head(rows)
      HTTP.response(200, json {
        executionMode : "paper",
        deploymentEnvironment : Env.get("DEPLOYMENT_ENVIRONMENT", "local"),
        paused : Map.get(row, "pause_entries") == "true" || Map.get(row, "pause_all") == "true",
        pauseEntries : Map.get(row, "pause_entries") == "true",
        pauseAll : Map.get(row, "pause_all") == "true",
        pauseReason : Map.get(row, "reason"),
        controlVersion : Map.get(row, "version"),
        leaderLeaseHolder : Map.get(row, "leader_holder"),
        leaderLeaseGeneration : Map.get(row, "leader_generation"),
        activePortfolios : Map.get(row, "active_portfolios"),
        liveNotional : json { atoms : Map.get(row, "live_notional"), scale : 6 },
        codeCommit : code_commit(),
        meshCommit : mesh_commit(),
        signerReachable : false,
        shutdownRequested : Process.shutdown_requested()
      })
    end
    Err(reason) -> error_response(500, "query_failed", reason)
  end
end

pub fn handle_opportunities(_request :: Request) -> Response do
  case (get_pool() |> list_opportunities) do
    Ok(body) -> HTTP.response(200, body)
    Err(reason) -> error_response(500, "query_failed", reason)
  end
end

pub fn handle_adapter_status(_request :: Request) -> Response do
  case load_runtime_config() do
    Ok(config) -> read_response(adapter_status(
      get_pool(),
      DateTime.utc_now() |> DateTime.to_unix_ms,
      config.max_source_age_ms
    ))
    Err(reason) -> error_response(503, "config_unavailable", reason)
  end
end

pub fn handle_executor_status(_request :: Request) -> Response do
  HTTP.response(200, json {
    enabled : false,
    executionMode : "paper",
    reachable : false,
    signerReachable : false,
    policyVersion : "not_installed"
  })
end

pub fn handle_strategies(_request :: Request) -> Response do
  read_response(get_pool() |> strategies)
end

pub fn handle_portfolios(_request :: Request) -> Response do
  read_response(get_pool() |> portfolios)
end

pub fn handle_portfolio(request :: Request) -> Response do
  case Request.param(request, "portfolio") do
    Some(portfolio_id) -> do
      case portfolio(get_pool(), portfolio_id) do
        Ok("null") -> error_response(404, "not_found", "paper portfolio not found")
        Ok(body) -> HTTP.response(200, body)
        Err(reason) -> error_response(500, "query_failed", reason)
      end
    end
    None -> error_response(400, "invalid_request", "missing portfolio")
  end
end

pub fn handle_positions(_request :: Request) -> Response do
  read_response(get_pool() |> positions)
end

pub fn handle_orders(request :: Request) -> Response do
  case page(request) do
    Ok(value) -> read_response(orders(get_pool(), value.limit, value.offset))
    Err(reason) -> error_response(400, "invalid_pagination", reason)
  end
end

pub fn handle_shadow_results(request :: Request) -> Response do
  case page(request) do
    Ok(value) -> read_response(shadow_results(
      get_pool(),
      value.limit,
      value.offset
    ))
    Err(reason) -> error_response(400, "invalid_pagination", reason)
  end
end

pub fn handle_shadow_result(request :: Request) -> Response do
  let body = Request.body(request)
  if authenticated(request, body) == false do
    return error_response(401, "unauthorized", "invalid adapter signature")
  end
  case parse_shadow_result(body) do
    Err(reason) -> error_response(400, "invalid_shadow_result", reason)
    Ok(result) -> case persist_shadow_result(get_pool(), result) do
      Ok(status) -> do
        info("shadow_result_recorded", "{\"commandId\":\"${result.command_id}\",\"status\":\"${status}\",\"outcome\":\"${result.status}\"}")
        HTTP.response(202, json {
          status : status,
          commandId : result.command_id,
          outcome : result.status,
          retryAllowed : result.status != "UNKNOWN"
        })
      end
      Err(reason) -> do
        if String.contains(reason, "shadow command binding changed") || String.contains(reason, "terminal shadow result changed") do
          error_response(409, "shadow_command_conflict", reason)
        else
          error_response(500, "persistence_failed", reason)
        end
      end
    end
  end
end

pub fn handle_fills(request :: Request) -> Response do
  case page(request) do
    Ok(value) -> read_response(fills(get_pool(), value.limit, value.offset))
    Err(reason) -> error_response(400, "invalid_pagination", reason)
  end
end

pub fn handle_funding(request :: Request) -> Response do
  case page(request) do
    Ok(value) -> read_response(funding(get_pool(), value.limit, value.offset))
    Err(reason) -> error_response(400, "invalid_pagination", reason)
  end
end

pub fn handle_funding_leaderboard(_request :: Request) -> Response do
  case load_runtime_config() do
    Ok(config) -> read_response(funding_leaderboard(
      get_pool(),
      DateTime.utc_now() |> DateTime.to_unix_ms,
      config.source_max_funding_age_ms,
      config.target_notional_usd_micros,
      config.paper_costs_usd_micros,
      config.paper_risk_haircut_usd_micros,
      config.expected_hold_hours
    ))
    Err(reason) -> error_response(503, "config_unavailable", reason)
  end
end

pub fn handle_reverse_carry_leaderboard(_request :: Request) -> Response do
  case load_runtime_config() do
    Ok(config) -> read_response(reverse_carry_leaderboard(
      get_pool(),
      DateTime.utc_now() |> DateTime.to_unix_ms,
      config.source_max_funding_age_ms,
      config.source_max_borrow_age_ms,
      config.target_notional_usd_micros,
      config.paper_costs_usd_micros,
      config.paper_risk_haircut_usd_micros,
      config.expected_hold_hours,
      config.maximum_break_even_hours,
      config.reverse_minimum_negative_funding_ppm,
      config.reverse_maximum_borrow_utilization_ppm
    ))
    Err(reason) -> error_response(503, "config_unavailable", reason)
  end
end

pub fn handle_cross_venue_funding_leaderboard(
  _request :: Request
) -> Response do
  case load_runtime_config() do
    Ok(config) -> read_response(cross_venue_funding_leaderboard(
      get_pool(),
      DateTime.utc_now() |> DateTime.to_unix_ms,
      config.source_max_funding_age_ms,
      config.target_notional_usd_micros,
      config.paper_costs_usd_micros,
      config.paper_risk_haircut_usd_micros,
      config.expected_hold_hours,
      config.paper_collateral_usd_micros,
      config.minimum_margin_ratio_ppm,
      config.minimum_liquidation_distance_bps
    ))
    Err(reason) -> error_response(503, "config_unavailable", reason)
  end
end

pub fn handle_wallet_tracking(_request :: Request) -> Response do
  read_response(wallet_tracking(
    get_pool(),
    DateTime.utc_now() |> DateTime.to_unix_ms
  ))
end

pub fn handle_solana_wallet_flow(_request :: Request) -> Response do
  read_response(get_pool() |> solana_wallet_flow_state)
end

pub fn handle_wallet_config(_request :: Request) -> Response do
  read_response(get_pool() |> wallet_config)
end

pub fn handle_wallet_config_update(request :: Request) -> Response do
  wallet_config_response(request)
end

pub fn handle_jitosol(_request :: Request) -> Response do
  read_response(get_pool() |> jitosol)
end

pub fn handle_pnl(_request :: Request) -> Response do
  read_response(get_pool() |> pnl)
end

pub fn handle_pnl_comparison(_request :: Request) -> Response do
  read_response(get_pool() |> pnl_comparison)
end

pub fn handle_risk_events(request :: Request) -> Response do
  case page(request) do
    Ok(value) -> read_response(risk_events(get_pool(), value.limit, value.offset))
    Err(reason) -> error_response(400, "invalid_pagination", reason)
  end
end

pub fn handle_risk_decisions(request :: Request) -> Response do
  case page(request) do
    Ok(value) -> read_response(risk_decisions(get_pool(), value.limit, value.offset))
    Err(reason) -> error_response(400, "invalid_pagination", reason)
  end
end

pub fn handle_latest_reconciliation(_request :: Request) -> Response do
  read_response(get_pool() |> latest_reconciliation)
end

pub fn handle_config(_request :: Request) -> Response do
  case load_runtime_config() do
    Ok(config) -> HTTP.response(200, json {
      configHash : config |> runtime_config_hash,
      executionMode : config.execution_mode,
      adapterMode : config.adapter_mode,
      deploymentEnvironment : "local",
      emitIntervalMs : config.emit_interval_ms,
      fundingIntervalEvents : config.funding_interval_events,
      fundingScanIntervalMs : config.funding_scan_interval_ms,
      sourceMaxSlotDrift : config.source_max_slot_drift,
      sourceMaxFundingAgeMs : config.source_max_funding_age_ms,
      sourceMaxBorrowAgeMs : config.source_max_borrow_age_ms,
      targetNotionalUsdMicros : "${config.target_notional_usd_micros}",
      paperMaximumJitoSolAtoms : "${config.paper_maximum_jitosol_atoms}",
      paperCollateralUsdMicros : "${config.paper_collateral_usd_micros}",
      paperCostsUsdMicros : "${config.paper_costs_usd_micros}",
      paperRiskHaircutUsdMicros : "${config.paper_risk_haircut_usd_micros}",
      paperSlippageBps : config.paper_slippage_bps,
      expectedHoldHours : config.expected_hold_hours,
      maximumBreakEvenHours : config.maximum_break_even_hours,
      reverseMinimumNegativeFundingPpm : config.reverse_minimum_negative_funding_ppm,
      reverseMaximumBorrowUtilizationPpm : config.reverse_maximum_borrow_utilization_ppm,
      jitosolRewardHaircutPpm : config.jitosol_reward_haircut_ppm,
      maxSourceAgeMs : config.max_source_age_ms,
      minimumMarginRatioPpm : config.minimum_margin_ratio_ppm,
      minimumLiquidationDistanceBps : config.minimum_liquidation_distance_bps,
      rebalanceDeltaBps : config.rebalance_delta_bps,
      executionPolicyProfile : config.execution_policy_profile,
      executionIntentTtlMs : config.execution_intent_ttl_ms,
      maximumExecutionSlippageBps : config.maximum_execution_slippage_bps,
      directUnstakeScenario : config.direct_unstake_scenario,
      directUnstakeFeePpm : config.direct_unstake_fee_ppm,
      directUnstakeChainFeesUsdMicros : config.direct_unstake_chain_fees_usd_micros,
      directUnstakeHedgeCostUsdMicros : config.direct_unstake_hedge_cost_usd_micros,
      directUnstakeCapitalDelayHaircutUsdMicros : config.direct_unstake_capital_delay_haircut_usd_micros,
      directUnstakeFinalHedgeCloseCostUsdMicros : config.direct_unstake_final_hedge_close_cost_usd_micros,
      protocolSchemaVersion : 1,
      databaseSchemaVersion : 39,
      liveEnabled : false
    })
    Err(reason) -> error_response(503, "config_unavailable", reason)
  end
end

pub fn handle_metrics(_request :: Request) -> Response do
  let headers = Map.new()
    |> Map.put("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
  case load_runtime_config() do
    Ok(config) -> case (
      DateTime.utc_now()
      |> DateTime.to_unix_ms
      |2> render(get_pool(), config.max_source_age_ms)
    ) do
      Ok(body) -> body |2> HTTP.response_with_headers(200, headers)
      Err(reason) -> error_response(503, "metrics_unavailable", reason)
    end
    Err(reason) -> error_response(503, "config_unavailable", reason)
  end
end
