from Packages.BuildIdentity import code_commit, mesh_commit
from Packages.LeaderLease import lease_held
from Packages.Log import info, warn
from Packages.Metrics import render
from Packages.ProtocolContracts import FundingObservation, FundingSettlement, MarketSnapshot, parse_funding_observation, parse_funding_settlement, parse_market_snapshot
from Packages.ReadModels import adapter_status, fills, funding, funding_leaderboard, jitosol, latest_reconciliation, orders, pnl, portfolio, portfolios, positions, reverse_carry_leaderboard, risk_decisions, risk_events, strategies
from Packages.RuntimeConfig import load_runtime_config, runtime_config_hash
from Packages.SolanaWalletFlow import SolanaWalletFlowEvent, claim_solana_live, parse_solana_wallet_flow_event, persist_solana_tuning, persist_solana_validation, persist_solana_wallet_config, persist_solana_wallet_flow_event, persist_strategy_execution_mode, record_solana_live, solana_followed_wallets, solana_wallet_flow_state
from Packages.Storage import FundingPersistence, advance_direct_unstakes, list_opportunities, load_direct_unstake_funding_payments, persist_funding_observation, persist_funding_settlement, persist_market_snapshot, persist_operator_command, persist_paper_reset, persist_strategy_control, run_cross_asset_paper_scan, run_nav_discount_paper_cycle, run_reverse_carry_paper_scan
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












fn run_paper_cycle(body :: String, snapshot :: MarketSnapshot) -> Int ! String do
  let pool = get_pool()
  let config = load_runtime_config() ?
  let inserted = (body |2> persist_market_snapshot(pool, snapshot)) ?
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
  Ok(inserted)
end

fn persist_response(body :: String, snapshot :: MarketSnapshot) do
  case run_paper_cycle(body, snapshot) do
    Ok(inserted) -> do
      record_accepted()
      info("protocol_event_accepted", "{\"eventId\":\"${snapshot.event_id}\",\"inserted\":\"${inserted}\"}")
      HTTP.response(202, json {
        status : if inserted == 0 do "duplicate" else "accepted" end,
        eventId : snapshot.event_id
      })
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
  persist_response(body, snapshot)
end


fn funding_accepted_response(event :: FundingSettlement, result :: FundingPersistence) do
  HTTP.response(202, json {
    status : if result.inserted_event do "accepted" else "duplicate" end,
    eventId : event.event_id,
    payments : result.payments,
    counterfactualPayments : result.counterfactual_payments
  })
end


fn funding_response(body :: String, event :: FundingSettlement) do
  let pool = get_pool()
  case (event |2> load_direct_unstake_funding_payments(pool)) do
    Ok(counterfactual_payments) -> case persist_funding_settlement(
      pool,
      body,
      List.new(),
      counterfactual_payments
    ) do
      Ok(result) -> do
        record_accepted()
        info("funding_event_accepted", "{\"eventId\":\"${event.event_id}\",\"counterfactualPayments\":\"${result.counterfactual_payments}\"}")
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
  if action == "resume" || action == "strategy_start" do
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
      let request_hash = "${idempotency_key}\n${body}" |> Crypto.sha256
      let persisted = if action == "strategy_start" || action == "strategy_stop" do
        persist_strategy_control(
          get_pool(),
          target,
          action == "strategy_start",
          idempotency_key,
          reason,
          request_hash
        )
      else
        persist_operator_command(
          get_pool(),
          action,
          target,
          idempotency_key,
          reason,
          request_hash
        )
      end
      case persisted do
        Ok(result) -> do
          info("operator_command_applied", "{\"action\":\"${action}\",\"idempotencyKey\":\"${idempotency_key}\"}")
          HTTP.response(202, result)
        end
        Err(error) -> do
          if String.contains(error, "idempotency key reused") do
            error_response(409, "idempotency_conflict", "idempotency key reused for a different command")
          else
            if String.contains(error, "strategy requires at least one configured") do
              error_response(409, "strategy_precondition_failed", error)
            else
              if String.contains(error, "unknown strategy") do
                error_response(404, "not_found", "strategy not found")
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

fn wallet_config_values(body :: String, maximum :: Int) -> String ! String do
  let root = Json.parse(body) ?
  let wallets = (root |> Json.object_get("wallets")) ?
  let count = (wallets |> Json.array_length()) ?
  if count > maximum do
    Err("wallets must contain at most ${maximum} addresses")
  else
    Ok(wallets |> Json.encode)
  end
end

fn wallet_config_response(request :: Request) do
  let body = Request.body(request)
  let idempotency_key = request_header(request, "x-idempotency-key")
  let action = "solana_wallet_config"
  if operator_authenticated(request, idempotency_key, body) == false do
    warn("operator_command_rejected", "{\"action\":\"${action}\",\"reason\":\"authentication\"}")
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
  case wallet_config_values(body, 100) do
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
      case persist_solana_wallet_config(
        get_pool(),
        idempotency_key,
        reason,
        request_hash,
        wallets_json
      ) do
        Ok(result) -> do
          info("operator_command_applied", "{\"action\":\"${action}\",\"idempotencyKey\":\"${idempotency_key}\"}")
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

fn tuning_changes(body :: String) -> String ! String do
  let root = Json.parse(body) ?
  let changes = (root |> Json.object_get("changes")) ?
  Ok(changes |> Json.encode)
end

fn tuning_response(request :: Request) -> Response do
  let body = Request.body(request)
  let idempotency_key = request_header(request, "x-idempotency-key")
  let action = "solana_tuning"
  if operator_authenticated(request, idempotency_key, body) == false do
    warn("operator_command_rejected", "{\"action\":\"${action}\",\"reason\":\"authentication\"}")
    return error_response(401, "unauthorized", "invalid operator signature")
  end
  if Regex.is_match(~r/^[A-Za-z0-9:_-]{1,200}$/, idempotency_key) == false do
    return error_response(400, "invalid_request", "invalid idempotency key")
  end
  case lease_held(get_pool()) do
    Ok(true) -> ()
    Ok(false) -> do
      return error_response(409, "leader_required", "cannot tune without the writer lease")
    end
    Err(reason) -> do
      return error_response(503, "lease_unavailable", reason)
    end
  end
  if Json.is_string(body, "reason") == false do
    return error_response(400, "invalid_request", "reason must be a JSON string")
  end
  let reason = String.trim(Json.get(body, "reason"))
  if String.length(reason) == 0 || String.length(reason) > 500 do
    return error_response(400, "invalid_request", "reason must contain between 1 and 500 characters")
  end
  case tuning_changes(body) do
    Err(reason) -> error_response(400, "invalid_request", reason)
    Ok(changes_json) -> do
      let request_hash = "${idempotency_key}\n${body}" |> Crypto.sha256
      case persist_solana_tuning(
        get_pool(),
        idempotency_key,
        reason,
        request_hash,
        changes_json
      ) do
        Ok(result) -> do
          info("operator_command_applied", "{\"action\":\"${action}\",\"idempotencyKey\":\"${idempotency_key}\"}")
          HTTP.response(202, result)
        end
        Err(error) -> do
          if String.contains(error, "idempotency key reused") do
            error_response(409, "idempotency_conflict", "idempotency key reused for a different command")
          else if String.contains(error, "cannot tune") do
            error_response(409, "tuning_locked", error)
          else if String.contains(error, "parameter") || String.contains(error, "invalid Solana tuning") || String.contains(error, "no parameter changed") do
            error_response(400, "invalid_tuning", error)
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

fn solana_validation_response(request :: Request, operation :: String) do
  let body = Request.body(request)
  let idempotency_key = request_header(request, "x-idempotency-key")
  if operator_authenticated(request, idempotency_key, body) == false do
    warn("operator_command_rejected", "{\"action\":\"solana_validation_${operation}\",\"reason\":\"authentication\"}")
    return error_response(401, "unauthorized", "invalid operator signature")
  end
  if Regex.is_match(~r/^[A-Za-z0-9:_-]{1,200}$/, idempotency_key) == false do
    return error_response(400, "invalid_request", "invalid idempotency key")
  end
  case lease_held(get_pool()) do
    Ok(true) -> ()
    Ok(false) -> do
      return error_response(409, "leader_required", "validation writes require the writer lease")
    end
    Err(reason) -> do
      return error_response(503, "lease_unavailable", reason)
    end
  end
  case Json.parse(body) do
    Err(reason) -> error_response(400, "invalid_request", reason)
    Ok(_parsed) -> case persist_solana_validation(get_pool(), operation, body) do
      Ok(result) -> do
        info("operator_command_applied", "{\"action\":\"solana_validation_${operation}\",\"idempotencyKey\":\"${idempotency_key}\"}")
        HTTP.response(202, result)
      end
      Err(reason) -> do
        if String.contains(reason, "invalid") || String.contains(reason, "must start") do
          error_response(400, "invalid_request", reason)
        else if String.contains(reason, "conflict") || String.contains(reason, "duplicate") do
          error_response(409, "evidence_conflict", reason)
        else
          error_response(500, "validation_write_failed", reason)
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

pub fn handle_strategy_start(request :: Request) -> Response do
  case Request.param(request, "strategy") do
    Some(strategy) -> operator_response(request, "strategy_start", strategy)
    None -> error_response(400, "invalid_request", "missing strategy")
  end
end

pub fn handle_strategy_stop(request :: Request) -> Response do
  case Request.param(request, "strategy") do
    Some(strategy) -> operator_response(request, "strategy_stop", strategy)
    None -> error_response(400, "invalid_request", "missing strategy")
  end
end

pub fn handle_reconcile(request :: Request) -> Response do
  operator_response(request, "reconcile", "")
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

fn strategy_mode_response(request :: Request, strategy :: String) do
  let body = Request.body(request)
  let idempotency_key = request_header(request, "x-idempotency-key")
  if operator_authenticated(request, idempotency_key, body) == false do
    warn("operator_command_rejected", "{\"action\":\"strategy_mode\",\"reason\":\"authentication\"}")
    return error_response(401, "unauthorized", "invalid operator signature")
  end
  if Regex.is_match(~r/^[A-Za-z0-9:_-]{1,200}$/, idempotency_key) == false do
    return error_response(400, "invalid_request", "invalid idempotency key")
  end
  case Json.parse(body) do
    Err(reason) -> error_response(400, "invalid_request", reason)
    Ok(_parsed) -> do
      if Json.is_string(body, "mode") == false do
        return error_response(400, "invalid_request", "mode must be a JSON string")
      end
      let mode = Json.get(body, "mode")
      if mode != "paper" && mode != "live" do
        return error_response(400, "invalid_request", "mode must be paper or live")
      end
      if Json.is_string(body, "reason") == false do
        return error_response(400, "invalid_request", "reason must be a JSON string")
      end
      let reason = String.trim(Json.get(body, "reason"))
      if String.length(reason) == 0 || String.length(reason) > 500 do
        return error_response(400, "invalid_request", "reason must contain between 1 and 500 characters")
      end
      let approval = if Json.is_string(body, "approval") do
        Json.get(body, "approval")
      else
        ""
      end
      if mode == "live" do
        case lease_held(get_pool()) do
          Ok(true) -> ()
          Ok(false) -> do
            return error_response(409, "leader_required", "cannot arm live without the writer lease")
          end
          Err(reason) -> do
            return error_response(503, "lease_unavailable", reason)
          end
        end
      end
      let request_hash = "${idempotency_key}\n${body}" |> Crypto.sha256
      case persist_strategy_execution_mode(
        get_pool(),
        strategy,
        mode,
        approval,
        idempotency_key,
        reason,
        request_hash
      ) do
        Ok(result) -> do
          info("operator_command_applied", "{\"action\":\"strategy_mode\",\"idempotencyKey\":\"${idempotency_key}\"}")
          HTTP.response(202, result)
        end
        Err(error) -> do
          if String.contains(error, "idempotency key reused") do
            error_response(409, "idempotency_conflict", "idempotency key reused for a different command")
          else if String.contains(error, "approval string") do
            error_response(409, "live_approval_required", error)
          else if String.contains(error, "live arming requires") do
            error_response(409, "strategy_precondition_failed", error)
          else if String.contains(error, "unknown strategy") do
            error_response(404, "not_found", "strategy not found")
          else
            error_response(500, "operator_command_failed", error)
          end
        end
      end
    end
  end
end

pub fn handle_strategy_mode(request :: Request) -> Response do
  case Request.param(request, "strategy") do
    Some(strategy) -> strategy_mode_response(request, strategy)
    None -> error_response(400, "invalid_request", "missing strategy")
  end
end

pub fn handle_solana_live_claim(request :: Request) -> Response do
  let body = Request.body(request)
  if authenticated(request, body) == false do
    warn("live_claim_rejected", "{\"reason\":\"authentication\"}")
    return error_response(401, "unauthorized", "invalid adapter signature")
  end
  case lease_held(get_pool()) do
    Ok(true) -> case claim_solana_live(get_pool(), body) do
      Ok(result) -> HTTP.response(200, result)
      Err(reason) -> do
        if String.contains(reason, "invalid") do
          error_response(400, "invalid_request", reason)
        else
          error_response(500, "live_claim_failed", reason)
        end
      end
    end
    Ok(false) -> error_response(503, "leader_required", "collector does not hold the writer lease")
    Err(reason) -> error_response(503, "lease_unavailable", reason)
  end
end

pub fn handle_solana_live_report(request :: Request) -> Response do
  let body = Request.body(request)
  if authenticated(request, body) == false do
    warn("live_report_rejected", "{\"reason\":\"authentication\"}")
    return error_response(401, "unauthorized", "invalid adapter signature")
  end
  case lease_held(get_pool()) do
    Ok(true) -> case record_solana_live(get_pool(), body) do
      Ok(result) -> HTTP.response(202, result)
      Err(reason) -> do
        if String.contains(reason, "invalid") do
          error_response(400, "invalid_request", reason)
        else if String.contains(reason, "no rows") do
          error_response(404, "not_found", "live intent not found")
        else
          error_response(500, "live_report_failed", reason)
        end
      end
    end
    Ok(false) -> error_response(503, "leader_required", "collector does not hold the writer lease")
    Err(reason) -> error_response(503, "lease_unavailable", reason)
  end
end

pub fn handle_solana_validation_start(request :: Request) -> Response do
  solana_validation_response(request, "start")
end

pub fn handle_solana_validation_evidence(request :: Request) -> Response do
  solana_validation_response(request, "evidence")
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
      schemaVersion : 57
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



pub fn handle_solana_wallet_flow(_request :: Request) -> Response do
  read_response(get_pool() |> solana_wallet_flow_state)
end

pub fn handle_solana_wallet_config(_request :: Request) -> Response do
  read_response(get_pool() |> solana_followed_wallets)
end

pub fn handle_solana_wallet_config_update(request :: Request) -> Response do
  wallet_config_response(request)
end

pub fn handle_solana_tuning(request :: Request) -> Response do
  tuning_response(request)
end



pub fn handle_jitosol(_request :: Request) -> Response do
  read_response(get_pool() |> jitosol)
end

pub fn handle_pnl(_request :: Request) -> Response do
  read_response(get_pool() |> pnl)
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
      databaseSchemaVersion : 57,
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
