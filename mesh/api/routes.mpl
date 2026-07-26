from Packages.Accounting import realized_funding_usd
from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros
from Packages.Log import info, warn
from Packages.Metrics import render
from Packages.Opportunity import OpportunitySet, evaluate_snapshot
from Packages.PaperEngine import PaperRuntime, PaperVariant, plan_entry, plan_position
from Packages.ProtocolContracts import FundingSettlement, MarketSnapshot, parse_funding_settlement, parse_market_snapshot
from Packages.StateMachine import PortfolioState
from Packages.Storage import FundingPersistence, list_opportunities, load_paper_position, load_paper_runtime, persist_funding_settlement, persist_opportunities, persist_paper_plan, persist_position_plan
from Runtime.Registry import get_pool, record_accepted, record_rejected

fn error_response(status :: Int, code :: String, message :: String) do
  HTTP.response(status, json { error : code, message : message })
end

fn request_signature(request :: Request) -> String do
  case Request.header(request, "x-adapter-signature") do
    Some(signature) -> signature
    None -> ""
  end
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
    let plan = (runtime |4> plan_entry(snapshot, result, variant)) ?
    plan |6> persist_paper_plan(pool, snapshot, result, portfolio_id, runtime)
  else
    if runtime.state == Hedged do
      let position = (portfolio_id |2> load_paper_position(pool)) ?
      let plan = (position |3> plan_position(snapshot,
      result,
      Env.get_int("REBALANCE_DELTA_BPS", 50))) ?
      plan |5> persist_position_plan(pool, snapshot, portfolio_id, position)
    else
      Ok(0)
    end
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

pub fn handle_event(request :: Request) -> Response do
  let body = Request.body(request)
  if authenticated(request, body) == false do
    record_rejected()
    warn("protocol_event_rejected", "{\"reason\":\"authentication\"}")
    error_response(401, "unauthorized", "invalid adapter signature")
  else
    authenticated_event_response(body)
  end
end

pub fn handle_health(_request :: Request) -> Response do
  case ("SELECT 1 AS ok" |2> Pool.query(get_pool(), [])) do
    Ok(rows) -> HTTP.response(200, json { status : "ok", database : "ok", mode : "paper" })
    Err(reason) -> error_response(503, "database_unavailable", reason)
  end
end

pub fn handle_build(_request :: Request) -> Response do
  HTTP.response(200, json {
    codeCommit : Env.get("CODE_COMMIT", "development"),
    meshCommit : Env.get("MESH_COMMIT", "dc36f28c549bc628b9106a6b90ce6a5b3c293a89"),
    configHash : Env.get("CONFIG_HASH", ""),
    schemaVersion : 6
  })
end

pub fn handle_capabilities(_request :: Request) -> Response do
  HTTP.response(200, "{\"schemaVersion\":1,\"implemented\":[\"MESH-FIN-001\",\"MESH-FIN-002\",\"MESH-TIME-001\",\"MESH-TEST-001\",\"MESH-TEST-002\",\"MESH-ACTOR-001-item-bound\",\"MESH-PROC-001\",\"MESH-OBS-001\",\"MESH-METRICS-001\",\"MESH-PROTO-001\"],\"bridged\":[\"MESH-BYTES-001\",\"MESH-CODEC-001\",\"MESH-NUM-001\",\"MESH-WS-001\",\"MESH-SOL-READ-001\"],\"deferred\":[\"MESH-SOL-TX-001\",\"MESH-SECRET-001\",\"MESH-CRYPTO-001\",\"MESH-SIGNER-001\"]}")
end

pub fn handle_status(_request :: Request) -> Response do
  HTTP.response(200, json {
    executionMode : "paper",
    deploymentEnvironment : "local",
    paused : false,
    liveNotionalAtoms : "0",
    signerReachable : false,
    shutdownRequested : Process.shutdown_requested()
  })
end

pub fn handle_opportunities(_request :: Request) -> Response do
  case (get_pool() |> list_opportunities) do
    Ok(body) -> HTTP.response(200, body)
    Err(reason) -> error_response(500, "query_failed", reason)
  end
end

pub fn handle_metrics(_request :: Request) -> Response do
  let headers = Map.new()
    |> Map.put("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
  render() |2> HTTP.response_with_headers(200, headers)
end
