from Packages.Accounting import realized_funding_usd
from Packages.Finance import Lamports, TokenAtoms
from Packages.Opportunity import OpportunitySet, evaluate_snapshot
from Packages.PaperEngine import EntryOutcome, PaperAction, PaperPlan, PaperPosition, PaperRuntime, PaperVariant, PositionPlan, action_name, outcome_name, plan_entry, plan_position, variant_name
from Packages.ProtocolContracts import FundingSettlement, MarketSnapshot, parse_funding_settlement, parse_market_snapshot
from Packages.StateMachine import PortfolioState

struct ReplayConfig do
  seed :: Int
  max_source_age_ms :: Int
  rebalance_delta_bps :: Int
end

struct ReplayManifest do
  bundle_id :: String
  config_hash :: String
end

struct EventMeta do
  event_type :: String
  observed_at_ms :: Int
  source_slot :: Int
  idempotency_key :: String
end

type ReplayPortfolio do
  ReplayIdle(PaperVariant, Int)
  ReplayOpen(PaperPosition)
  ReplayStopped(PaperVariant, Int, String)
end

struct PortfolioStep do
  portfolio :: ReplayPortfolio
  trace :: String
  entries :: Int
  exits :: Int
  rebalances :: Int
  emergencies :: Int
  reward_lamports :: Int
  basis_lamports :: Int
end

struct ReplayState do
  sol :: ReplayPortfolio
  jitosol :: ReplayPortfolio
  event_count :: Int
  decision_count :: Int
  sol_entries :: Int
  jitosol_entries :: Int
  sol_exits :: Int
  jitosol_exits :: Int
  sol_rebalances :: Int
  jitosol_rebalances :: Int
  sol_emergencies :: Int
  jitosol_emergencies :: Int
  sol_reward_lamports :: Int
  jitosol_reward_lamports :: Int
  sol_basis_lamports :: Int
  jitosol_basis_lamports :: Int
  sol_funding_usd_micros :: Int
  jitosol_funding_usd_micros :: Int
  last_observed_at_ms :: Int
  last_source_slot :: Int
  last_event_rank :: Int
  has_last_event :: Bool
  # ponytail: linear lookup is enough for bounded local bundles; use a String Set when Mesh supports it.
  seen :: List<String>
  trace :: List<String>
end

pub struct ReplayReport do
  replay_schema_version :: Int
  bundle_id :: String
  config_hash :: String
  mesh_commit :: String
  event_count :: Int
  decision_count :: Int
  sol_entries :: Int
  jitosol_entries :: Int
  sol_exits :: Int
  jitosol_exits :: Int
  sol_rebalances :: Int
  jitosol_rebalances :: Int
  sol_emergencies :: Int
  jitosol_emergencies :: Int
  sol_reward_lamports :: Int
  jitosol_reward_lamports :: Int
  sol_basis_lamports :: Int
  jitosol_basis_lamports :: Int
  sol_funding_usd_micros :: Int
  jitosol_funding_usd_micros :: Int
  trace_hash :: String
end deriving(Json)

fn required_string(body :: String, key :: String) -> String ! String do
  if Json.is_string(body, key) == false do
    return Err("${key} must be a JSON string")
  end
  let value = body
    |> Json.get(key)
  if String.length(value) == 0 do
    Err("${key} is required")
  else
    Ok(value)
  end
end

fn required_int(body :: String, key :: String) -> Int ! String do
  let raw = (body
    |> required_string(key)) ?
  if Regex.is_match(~r/^(0|[1-9][0-9]*)$/, raw) == false do
    return Err("${key} must be a canonical non-negative integer string")
  end
  case String.to_int(raw) do
    Some(value) -> Ok(value)
    None -> Err("${key} is outside the supported integer range")
  end
end

fn schema_version(body :: String) -> Int ! String do
  case (body
    |> Json.get("replaySchemaVersion")
    |> String.to_int) do
    Some(1) -> Ok(1)
    _ -> Err("unsupported replay schema version")
  end
end

fn parse_config(body :: String) -> ReplayConfig ! String do
  Json.parse(body) ?
  schema_version(body) ?
  Ok(ReplayConfig {
    seed : (body
      |> required_int("seed")) ?,
    max_source_age_ms : (body
      |> required_int("maxSourceAgeMs")) ?,
    rebalance_delta_bps : (body
      |> required_int("rebalanceDeltaBps")) ?
  })
end

fn parse_manifest(body :: String, config_body :: String, mesh_commit :: String) -> ReplayManifest ! String do
  Json.parse(body) ?
  schema_version(body) ?
  let config_hash = (body
    |> required_string("configHash")) ?
  if config_hash != Crypto.sha256(config_body) do
    return Err("replay config hash does not match bundle manifest")
  end
  let manifest_mesh_commit = (body
    |> required_string("meshCommit")) ?
  if manifest_mesh_commit != mesh_commit do
    return Err("replay Mesh commit does not match running toolchain")
  end
  Ok(ReplayManifest {
    bundle_id : (body
      |> required_string("bundleId")) ?,
    config_hash : config_hash
  })
end

fn event_meta(body :: String) -> EventMeta ! String do
  Json.parse(body) ?
  Ok(EventMeta {
    event_type : (body
      |> required_string("eventType")) ?,
    observed_at_ms : (body
      |> required_int("observedAtMs")) ?,
    source_slot : (body
      |> required_int("sourceSlot")) ?,
    idempotency_key : (body
      |> required_string("idempotencyKey")) ?
  })
end

fn event_rank(event_type :: String) -> Int do
  if event_type == "MarketSnapshot" do
    0
  else
    1
  end
end

fn canonical_after(state :: ReplayState, event :: EventMeta) -> Bool do
  if state.has_last_event == false || event.observed_at_ms > state.last_observed_at_ms do
    true
  else
    if event.observed_at_ms < state.last_observed_at_ms do
      false
    else
      if event.source_slot > state.last_source_slot do
        true
      else
        if event.source_slot < state.last_source_slot do
          false
        else
          event_rank(event.event_type) > state.last_event_rank
        end
      end
    end
  end
end

fn initial_state(seed :: Int) -> ReplayState do
  ReplayState {
    sol : ReplayIdle(SolControl, Random.seed(seed)),
    jitosol : ReplayIdle(JitoSolCarry, Random.seed(seed)),
    event_count : 0,
    decision_count : 0,
    sol_entries : 0,
    jitosol_entries : 0,
    sol_exits : 0,
    jitosol_exits : 0,
    sol_rebalances : 0,
    jitosol_rebalances : 0,
    sol_emergencies : 0,
    jitosol_emergencies : 0,
    sol_reward_lamports : 0,
    jitosol_reward_lamports : 0,
    sol_basis_lamports : 0,
    jitosol_basis_lamports : 0,
    sol_funding_usd_micros : 0,
    jitosol_funding_usd_micros : 0,
    last_observed_at_ms : 0,
    last_source_slot : 0,
    last_event_rank : 0,
    has_last_event : false,
    seen : List.new(),
    trace : List.new()
  }
end

fn market_rate(snapshot :: MarketSnapshot, variant :: PaperVariant) -> Lamports ! String do
  case variant do
    SolControl -> Ok(Lamports { atoms : 1000000000 })
    JitoSolCarry -> Ok(Lamports { atoms : (snapshot.jitosol_spot_bid_price_usd_micros.atoms
      |> Checked.mul_div(1000000000, snapshot.sol_price_usd_micros.atoms, :floor)) ? })
  end
end

fn open_position(
  snapshot :: MarketSnapshot,
  opportunity :: OpportunitySet,
  variant :: PaperVariant,
  plan :: PaperPlan
) -> PaperPosition ! String do
  Ok(PaperPosition {
    variant : variant,
    spot_quantity : TokenAtoms { atoms : plan.spot_fill.filled_quantity.atoms },
    perp_short_quantity : Lamports { atoms : plan.perp_fill.filled_quantity.atoms },
    prior_nav_lamports : if variant == SolControl do
      Lamports { atoms : 1000000000 }
    else
      opportunity.nav_lamports
    end,
    prior_market_rate_lamports : market_rate(snapshot, variant) ?,
    state_version : 4,
    random_state : plan.next_random_state
  })
end

fn entry_trace(
  snapshot :: MarketSnapshot,
  opportunity :: OpportunitySet,
  variant :: PaperVariant,
  plan :: PaperPlan
) -> String do
  let carry = if variant == SolControl do
    opportunity.sol_net_carry_usd_micros.atoms
  else
    opportunity.jitosol_net_carry_usd_micros.atoms
  end
  "${snapshot.observed_at_ms}|${snapshot.event_id}|${variant_name(variant)}|entry|${outcome_name(plan.outcome)}|${plan.reason}|${plan.spot_fill.filled_quantity.atoms}|${plan.perp_fill.filled_quantity.atoms}|${carry}|${plan.next_random_state}"
end

fn step_idle(
  snapshot :: MarketSnapshot,
  opportunity :: OpportunitySet,
  config :: ReplayConfig,
  variant :: PaperVariant,
  random_state :: Int
) -> PortfolioStep ! String do
  let plan = (PaperRuntime {
    now_ms : snapshot.observed_at_ms,
    max_age_ms : config.max_source_age_ms,
    paused : false,
    pause_all : false,
    state : Idle,
    state_version : 0,
    random_state : random_state
  } |4> plan_entry(snapshot, opportunity, variant)) ?
  let trace = entry_trace(snapshot, opportunity, variant, plan)
  case plan.outcome do
    EntryHedged -> Ok(PortfolioStep {
      portfolio : ReplayOpen(open_position(snapshot, opportunity, variant, plan) ?),
      trace : trace,
      entries : 1,
      exits : 0,
      rebalances : 0,
      emergencies : 0,
      reward_lamports : 0,
      basis_lamports : 0
    })
    EntrySkipped -> Ok(PortfolioStep {
      portfolio : ReplayIdle(variant, plan.next_random_state),
      trace : trace,
      entries : 0,
      exits : 0,
      rebalances : 0,
      emergencies : 0,
      reward_lamports : 0,
      basis_lamports : 0
    })
    _ -> Ok(PortfolioStep {
      portfolio : ReplayStopped(variant, plan.next_random_state, plan.reason),
      trace : trace,
      entries : 0,
      exits : 0,
      rebalances : 0,
      emergencies : 1,
      reward_lamports : 0,
      basis_lamports : 0
    })
  end
end

fn next_position(position :: PaperPosition, plan :: PositionPlan) -> PaperPosition do
  %{position |
    spot_quantity : plan.next_spot_quantity,
    perp_short_quantity : plan.next_perp_short_quantity,
    prior_nav_lamports : plan.valuation.protocol_nav_lamports,
    prior_market_rate_lamports : plan.valuation.market_rate_lamports,
    state_version : position.state_version + if plan.action == RebalancePerp do
      2
    else
      0
    end,
    random_state : plan.next_random_state
  }
end

fn position_trace(snapshot :: MarketSnapshot, position :: PaperPosition, plan :: PositionPlan) -> String do
  "${snapshot.observed_at_ms}|${snapshot.event_id}|${variant_name(position.variant)}|position|${action_name(plan.action)}|${plan.reason}|${plan.next_spot_quantity.atoms}|${plan.next_perp_short_quantity.atoms}|${plan.valuation.delta_lamports.atoms}|${plan.next_random_state}"
end

fn step_open(
  snapshot :: MarketSnapshot,
  opportunity :: OpportunitySet,
  config :: ReplayConfig,
  position :: PaperPosition
) -> PortfolioStep ! String do
  let plan = (position |3> plan_position(
    snapshot,
    opportunity,
    snapshot.observed_at_ms,
    config.max_source_age_ms,
    config.rebalance_delta_bps
  )) ?
  let trace = position_trace(snapshot, position, plan)
  case plan.action do
    ExitPosition -> Ok(PortfolioStep {
      portfolio : ReplayIdle(position.variant, plan.next_random_state),
      trace : trace,
      entries : 0,
      exits : 1,
      rebalances : 0,
      emergencies : 0,
      reward_lamports : plan.valuation.reward_sol_lamports.atoms,
      basis_lamports : plan.valuation.basis_sol_lamports.atoms
    })
    EmergencyPosition -> Ok(PortfolioStep {
      portfolio : ReplayStopped(position.variant, plan.next_random_state, plan.reason),
      trace : trace,
      entries : 0,
      exits : 0,
      rebalances : 0,
      emergencies : 1,
      reward_lamports : plan.valuation.reward_sol_lamports.atoms,
      basis_lamports : plan.valuation.basis_sol_lamports.atoms
    })
    _ -> Ok(PortfolioStep {
      portfolio : ReplayOpen(next_position(position, plan)),
      trace : trace,
      entries : 0,
      exits : 0,
      rebalances : if plan.action == RebalancePerp do 1 else 0 end,
      emergencies : 0,
      reward_lamports : plan.valuation.reward_sol_lamports.atoms,
      basis_lamports : plan.valuation.basis_sol_lamports.atoms
    })
  end
end

fn step_portfolio(
  snapshot :: MarketSnapshot,
  opportunity :: OpportunitySet,
  config :: ReplayConfig,
  portfolio :: ReplayPortfolio
) -> PortfolioStep ! String do
  case portfolio do
    ReplayIdle(variant, random_state) -> step_idle(
      snapshot,
      opportunity,
      config,
      variant,
      random_state
    )
    ReplayOpen(position) -> step_open(snapshot, opportunity, config, position)
    ReplayStopped(variant, random_state, reason) -> Ok(PortfolioStep {
      portfolio : ReplayStopped(variant, random_state, reason),
      trace : "${snapshot.observed_at_ms}|${snapshot.event_id}|${variant_name(variant)}|stopped|${reason}",
      entries : 0,
      exits : 0,
      rebalances : 0,
      emergencies : 0,
      reward_lamports : 0,
      basis_lamports : 0
    })
  end
end

fn apply_snapshot(
  state :: ReplayState,
  config :: ReplayConfig,
  snapshot :: MarketSnapshot
) -> ReplayState ! String do
  let opportunity = (snapshot
    |> evaluate_snapshot) ?
  let sol = (state.sol |4> step_portfolio(snapshot, opportunity, config)) ?
  let jitosol = (state.jitosol |4> step_portfolio(snapshot, opportunity, config)) ?
  Ok(%{state |
    sol : sol.portfolio,
    jitosol : jitosol.portfolio,
    event_count : state.event_count + 1,
    decision_count : state.decision_count + 2,
    sol_entries : state.sol_entries + sol.entries,
    jitosol_entries : state.jitosol_entries + jitosol.entries,
    sol_exits : state.sol_exits + sol.exits,
    jitosol_exits : state.jitosol_exits + jitosol.exits,
    sol_rebalances : state.sol_rebalances + sol.rebalances,
    jitosol_rebalances : state.jitosol_rebalances + jitosol.rebalances,
    sol_emergencies : state.sol_emergencies + sol.emergencies,
    jitosol_emergencies : state.jitosol_emergencies + jitosol.emergencies,
    sol_reward_lamports : (state.sol_reward_lamports
      |> Checked.add(sol.reward_lamports)) ?,
    jitosol_reward_lamports : (state.jitosol_reward_lamports
      |> Checked.add(jitosol.reward_lamports)) ?,
    sol_basis_lamports : (state.sol_basis_lamports
      |> Checked.add(sol.basis_lamports)) ?,
    jitosol_basis_lamports : (state.jitosol_basis_lamports
      |> Checked.add(jitosol.basis_lamports)) ?,
    trace : state.trace
      |> List.append(sol.trace)
      |> List.append(jitosol.trace)
  })
end

fn funding_amount(portfolio :: ReplayPortfolio, event :: FundingSettlement) -> Int ! String do
  case portfolio do
    ReplayOpen(position) -> do
      let amount = (position.perp_short_quantity
        |> realized_funding_usd(event.sol_price_usd_micros, event.realized_short_rate_ppm)) ?
      Ok(amount.atoms)
    end
    _ -> Ok(0)
  end
end

fn apply_funding(state :: ReplayState, event :: FundingSettlement) -> ReplayState ! String do
  let sol = funding_amount(state.sol, event) ?
  let jitosol = funding_amount(state.jitosol, event) ?
  Ok(%{state |
    event_count : state.event_count + 1,
    sol_funding_usd_micros : (state.sol_funding_usd_micros
      |> Checked.add(sol)) ?,
    jitosol_funding_usd_micros : (state.jitosol_funding_usd_micros
      |> Checked.add(jitosol)) ?,
    trace : state.trace
      |> List.append("${event.observed_at_ms}|${event.event_id}|funding|${sol}|${jitosol}")
  })
end

fn advance(state :: ReplayState, config :: ReplayConfig, event_body :: String) -> ReplayState ! String do
  let meta = (event_body
    |> event_meta) ?
  if List.contains(state.seen, meta.idempotency_key) do
    return Err("duplicate replay idempotency key")
  end
  if canonical_after(state, meta) == false do
    return Err("replay events are out of canonical order")
  end
  let next = (case meta.event_type do
    "MarketSnapshot" -> ((event_body
      |> parse_market_snapshot) ? |3> apply_snapshot(state, config))
    "FundingSettlement" -> ((event_body
      |> parse_funding_settlement) ? |2> apply_funding(state))
    _ -> Err("unsupported replay event type")
  end) ?
  Ok(%{next |
    last_observed_at_ms : meta.observed_at_ms,
    last_source_slot : meta.source_slot,
    last_event_rank : event_rank(meta.event_type),
    has_last_event : true,
    seen : state.seen |> List.append(meta.idempotency_key)
  })
end

fn replay_lines(
  config :: ReplayConfig,
  lines :: List<String>,
  index :: Int,
  state :: ReplayState
) -> ReplayState ! String do
  if index >= List.length(lines) do
    Ok(state)
  else
    replay_lines(config, lines, index + 1, advance(state, config, List.get(lines, index)) ?)
  end
end

pub fn run_replay(
  config_body :: String,
  bundle_body :: String,
  mesh_commit :: String
) -> ReplayReport ! String do
  let config = (config_body
    |> parse_config) ?
  let lines = for line in String.split(bundle_body, "\n") when String.length(String.trim(line)) > 0 do
    String.trim(line)
  end
  if List.length(lines) < 2 do
    return Err("replay bundle must contain a manifest and at least one event")
  end
  let manifest = (List.head(lines)
    |> parse_manifest(config_body, mesh_commit)) ?
  let state = replay_lines(config, List.drop(lines, 1), 0, initial_state(config.seed)) ?
  Ok(ReplayReport {
    replay_schema_version : 1,
    bundle_id : manifest.bundle_id,
    config_hash : manifest.config_hash,
    mesh_commit : mesh_commit,
    event_count : state.event_count,
    decision_count : state.decision_count,
    sol_entries : state.sol_entries,
    jitosol_entries : state.jitosol_entries,
    sol_exits : state.sol_exits,
    jitosol_exits : state.jitosol_exits,
    sol_rebalances : state.sol_rebalances,
    jitosol_rebalances : state.jitosol_rebalances,
    sol_emergencies : state.sol_emergencies,
    jitosol_emergencies : state.jitosol_emergencies,
    sol_reward_lamports : state.sol_reward_lamports,
    jitosol_reward_lamports : state.jitosol_reward_lamports,
    sol_basis_lamports : state.sol_basis_lamports,
    jitosol_basis_lamports : state.jitosol_basis_lamports,
    sol_funding_usd_micros : state.sol_funding_usd_micros,
    jitosol_funding_usd_micros : state.jitosol_funding_usd_micros,
    trace_hash : state.trace
      |> String.join("\n")
      |> Crypto.sha256
  })
end
