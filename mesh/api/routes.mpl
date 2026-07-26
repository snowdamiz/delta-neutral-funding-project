from Packages.Accounting import realized_funding_usd
from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros
from Packages.LeaderLease import lease_held
from Packages.Log import info, warn
from Packages.Metrics import render
from Packages.Opportunity import OpportunitySet, evaluate_snapshot
from Packages.PaperEngine import PaperRuntime, PaperVariant, plan_entry, plan_position
from Packages.ProtocolContracts import FundingSettlement, MarketSnapshot, parse_funding_settlement, parse_market_snapshot
from Packages.ReadModels import adapter_status, fills, funding, jitosol, latest_reconciliation, orders, pnl, pnl_comparison, portfolio, portfolios, positions, risk_events
from Packages.StateMachine import PortfolioState
from Packages.Storage import FundingPersistence, list_opportunities, load_paper_position, load_paper_runtime, persist_funding_settlement, persist_operator_command, persist_opportunities, persist_paper_plan, persist_position_plan
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
    let expected_signature = body |2> Crypto.hmac_sha256(secret)
    request_signature(request) |> Crypto.secure_compare(expected_signature)
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
    let signed_body = "${idempotency_key}\n${body}"
    let expected = signed_body |2> Crypto.hmac_sha256(secret)
    request_header(request, "x-operator-signature")
      |> Crypto.secure_compare(expected)
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
  if runtime.pause_all do
    return Ok(0)
  end
  if runtime.state == Idle do
    let plan = (runtime |4> plan_entry(snapshot, result, variant)) ?
    plan |6> persist_paper_plan(pool, snapshot, result, portfolio_id, runtime)
  else
    if runtime.state != Hedged do
      return Ok(0)
    end
    let position = (portfolio_id |2> load_paper_position(pool)) ?
    let plan = (position |3> plan_position(
      snapshot,
      result,
      Env.get_int("REBALANCE_DELTA_BPS", 50)
    )) ?
    plan |5> persist_position_plan(pool, snapshot, portfolio_id, position)
  end
end

fn run_paper_cycle(body :: String, snapshot :: MarketSnapshot, result :: OpportunitySet) -> Int ! String do
  let pool = get_pool()
  let inserted = (Env.get("CONFIG_HASH", "") |5> persist_opportunities(pool, body, snapshot, result)) ?
  let now_ms = DateTime.utc_now() |> DateTime.to_unix_ms
  let max_age_ms = Env.get_int("MAX_SOURCE_AGE_MS", 5000)
  let sol_runtime = ("local-sol-control" |2> load_paper_runtime(pool, now_ms, max_age_ms)) ?
  let jitosol_runtime = ("local-jitosol-carry" |2> load_paper_runtime(pool, now_ms, max_age_ms)) ?
  let _sol_applied = run_portfolio_cycle(pool, snapshot, result, "local-sol-control", SolControl, sol_runtime) ?
  let _jitosol_applied = run_portfolio_cycle(pool, snapshot, result, "local-jitosol-carry", JitoSolCarry, jitosol_runtime) ?
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
      error_response(500, "persistence_failed", reason)
    end
  end
end

fn evaluate_response(body :: String, snapshot :: MarketSnapshot) do
  case evaluate_snapshot(snapshot) do
    Ok(result) -> persist_response(body, snapshot, result)
    Err(reason) -> do
      record_rejected()
      error_response(422, "evaluation_failed", reason)
    end
  end
end

fn funding_payment(
  pool :: PoolHandle,
  portfolio_id :: String,
  event :: FundingSettlement,
  now_ms :: Int
) -> String ! String do
  let runtime = (portfolio_id |2> load_paper_runtime(
    pool,
    now_ms,
    Env.get_int("MAX_SOURCE_AGE_MS", 5000)
  )) ?
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
    payments : result.payments
  })
end

fn funding_response(body :: String, event :: FundingSettlement) do
  let pool = get_pool()
  let now_ms = DateTime.utc_now() |> DateTime.to_unix_ms
  case funding_payment(pool, "local-sol-control", event, now_ms) do
    Ok(sol_payment) -> do
      case funding_payment(pool, "local-jitosol-carry", event, now_ms) do
        Ok(jitosol_payment) -> do
          case persist_funding_settlement(
            pool,
            body,
            sol_payment,
            jitosol_payment
          ) do
            Ok(result) -> do
              record_accepted()
              info("funding_event_accepted", "{\"eventId\":\"${event.event_id}\",\"payments\":\"${result.payments}\"}")
              funding_accepted_response(event, result)
            end
            Err(reason) -> do
              record_rejected()
              error_response(500, "persistence_failed", reason)
            end
          end
        end
        Err(reason) -> do
          record_rejected()
          error_response(500, "funding_evaluation_failed", reason)
        end
      end
    end
    Err(reason) -> do
      record_rejected()
      error_response(500, "funding_evaluation_failed", reason)
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

fn operator_response(request :: Request, action :: String) do
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
      let request_hash = "${idempotency_key}\n${body}" |> Crypto.sha256
      case persist_operator_command(
        get_pool(),
        action,
        idempotency_key,
        reason,
        request_hash
      ) do
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
  operator_response(request, "pause_entries")
end

pub fn handle_pause_all(request :: Request) -> Response do
  operator_response(request, "pause_all")
end

pub fn handle_resume(request :: Request) -> Response do
  operator_response(request, "resume")
end

pub fn handle_reconcile(request :: Request) -> Response do
  operator_response(request, "reconcile")
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
  HTTP.response(200, json {
    codeCommit : Env.get("CODE_COMMIT", "development"),
    meshCommit : Env.get("MESH_COMMIT", "7256eba370b78fb16661fad298b6538e9bdb61c0"),
    configHash : Env.get("CONFIG_HASH", ""),
    schemaVersion : 8
  })
end

pub fn handle_capabilities(_request :: Request) -> Response do
  HTTP.response(200, "{\"schemaVersion\":1,\"implemented\":[\"MESH-FIN-001\",\"MESH-FIN-002\",\"MESH-TIME-001\",\"MESH-TEST-001\",\"MESH-TEST-002\",\"MESH-ACTOR-001-item-bound\",\"MESH-PROC-001\",\"MESH-OBS-001\",\"MESH-METRICS-001\",\"MESH-PROTO-001\"],\"bridged\":[\"MESH-BYTES-001\",\"MESH-CODEC-001\",\"MESH-NUM-001\",\"MESH-WS-001\",\"MESH-SOL-READ-001\"],\"deferred\":[\"MESH-SOL-TX-001\",\"MESH-SECRET-001\",\"MESH-CRYPTO-001\",\"MESH-SIGNER-001\"]}")
end

pub fn handle_status(_request :: Request) -> Response do
  case Pool.query(get_pool(), "SELECT c.pause_entries::text, c.pause_all::text, c.reason, c.version::text, COALESCE((SELECT holder_instance_id FROM leader_leases WHERE lease_name = 'collector'), '') AS leader_holder, COALESCE((SELECT generation::text FROM leader_leases WHERE lease_name = 'collector'), '0') AS leader_generation, (SELECT count(*)::text FROM portfolio_runs WHERE strategy_run_id = 'local-paper-run' AND state NOT IN ('idle', 'paused')) AS active_portfolios FROM control_state c", []) do
    Ok(rows) -> do
      let row = List.head(rows)
      HTTP.response(200, json {
        executionMode : "paper",
        deploymentEnvironment : "local",
        paused : Map.get(row, "pause_entries") == "true" || Map.get(row, "pause_all") == "true",
        pauseEntries : Map.get(row, "pause_entries") == "true",
        pauseAll : Map.get(row, "pause_all") == "true",
        pauseReason : Map.get(row, "reason"),
        controlVersion : Map.get(row, "version"),
        leaderLeaseHolder : Map.get(row, "leader_holder"),
        leaderLeaseGeneration : Map.get(row, "leader_generation"),
        activePortfolios : Map.get(row, "active_portfolios"),
        liveNotional : json { atoms : "0", scale : 6 },
        codeCommit : Env.get("CODE_COMMIT", "development"),
        meshCommit : Env.get("MESH_COMMIT", "7256eba370b78fb16661fad298b6538e9bdb61c0"),
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
  read_response(adapter_status(
    get_pool(),
    DateTime.utc_now() |> DateTime.to_unix_ms,
    Env.get_int("MAX_SOURCE_AGE_MS", 5000)
  ))
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

pub fn handle_latest_reconciliation(_request :: Request) -> Response do
  read_response(get_pool() |> latest_reconciliation)
end

pub fn handle_config(_request :: Request) -> Response do
  HTTP.response(200, json {
    configHash : Env.get("CONFIG_HASH", ""),
    executionMode : "paper",
    deploymentEnvironment : "local",
    maxSourceAgeMs : Env.get_int("MAX_SOURCE_AGE_MS", 5000),
    rebalanceDeltaBps : Env.get_int("REBALANCE_DELTA_BPS", 50),
    protocolSchemaVersion : 1,
    databaseSchemaVersion : 8,
    liveEnabled : false
  })
end

pub fn handle_metrics(_request :: Request) -> Response do
  let headers = Map.new()
    |> Map.put("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
  render() |2> HTTP.response_with_headers(200, headers)
end
