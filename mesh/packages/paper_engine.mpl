from Packages.BrokerPaper import FailureOutcome, FillStatus, OrderSide, PaperFill, PaperOrder, sample_failure, simulate_fill
from Packages.Finance import Lamports, PriceMicros, QuantityAtoms, RatePpm, UsdMicros, position_delta
from Packages.Opportunity import OpportunitySet
from Packages.ProtocolContracts import MarketSnapshot, OracleStatus
from Packages.RiskEngine import MarginInput, RiskInput, approve_entry, margin_health, source_health
from Packages.StateMachine import PortfolioSignal, PortfolioState, transition

pub type PaperVariant do
  SolControl
  
  JitoSolCarry
end deriving(Eq, Display, Json)

pub type EntryOutcome do
  EntrySkipped
  
  EntryHedged
  
  EntryPartial
  
  EntryRejected
  
  EntryUnknown
end deriving(Eq, Display, Json)

pub fn variant_name(variant :: PaperVariant) -> String do
  case variant do
    SolControl -> "sol_control"
    JitoSolCarry -> "jitosol_carry"
  end
end

pub fn variant_from_name(name :: String) -> PaperVariant ! String do
  case name do
    "sol_control" -> Ok(SolControl)
    "jitosol_carry" -> Ok(JitoSolCarry)
    _ -> Err("invalid paper variant")
  end
end

pub fn outcome_name(outcome :: EntryOutcome) -> String do
  case outcome do
    EntrySkipped -> "skipped"
    EntryHedged -> "hedged"
    EntryPartial -> "partial"
    EntryRejected -> "rejected"
    EntryUnknown -> "unknown"
  end
end

pub struct LegFill do
  placed :: Bool
  status :: FillStatus
  filled_quantity :: QuantityAtoms
  average_price :: PriceMicros
  gross_usd :: UsdMicros
  fee_usd :: UsdMicros
end deriving(Json)

pub struct PaperPlan do
  variant :: PaperVariant
  spot_asset :: String
  outcome :: EntryOutcome
  reason :: String
  next_state :: PortfolioState
  next_random_state :: Int
  spot_fill :: LegFill
  perp_fill :: LegFill
end

pub struct PaperRuntime do
  now_ms :: Int
  max_age_ms :: Int
  paused :: Bool
  pause_all :: Bool
  minimum_margin_ratio_ppm :: Int
  minimum_liquidation_distance_bps :: Int
  rebalance_delta_bps :: Int
  state :: PortfolioState
  state_version :: Int
  random_state :: Int
end

pub type PaperAction do
  HoldPosition

  RebalancePerp

  ExitPosition

  EmergencyPosition

  RecoverPosition
end deriving(Eq, Display, Json)

pub fn action_name(action :: PaperAction) -> String do
  case action do
    HoldPosition -> "hold"
    RebalancePerp -> "rebalance_perp"
    ExitPosition -> "exit"
    EmergencyPosition -> "emergency"
    RecoverPosition -> "recover"
  end
end

pub struct PaperPosition do
  variant :: PaperVariant
  spot_quantity :: TokenAtoms
  perp_short_quantity :: Lamports
  prior_nav_lamports :: Lamports
  prior_market_rate_lamports :: Lamports
  state_version :: Int
  random_state :: Int
end

pub struct PaperValuation do
  protocol_nav_lamports :: Lamports
  market_rate_lamports :: Lamports
  spot_equivalent_lamports :: Lamports
  delta_lamports :: Lamports
  delta_bps :: Int
  reward_sol_lamports :: Lamports
  basis_sol_lamports :: Lamports
end deriving(Json)

pub struct PositionPlan do
  action :: PaperAction
  reason :: String
  spot_asset :: String
  perp_side :: String
  spot_requested_quantity :: TokenAtoms
  perp_requested_quantity :: Lamports
  next_state :: PortfolioState
  next_random_state :: Int
  next_spot_quantity :: TokenAtoms
  next_perp_short_quantity :: Lamports
  valuation :: PaperValuation
  spot_fill :: LegFill
  perp_fill :: LegFill
end

pub fn position_risk_approved(plan :: PositionPlan) -> Bool do
  plan.action == RebalancePerp || (plan.action == HoldPosition && plan.reason == "within_delta_band")
end

struct PositionRequest do
  spot_quantity :: TokenAtoms
  perp_quantity :: Lamports
  perp_side :: String
end

struct SpotLeg do
  asset :: String
  quantity :: QuantityAtoms
  price :: PriceMicros
  exit_depth :: Lamports
  net_carry :: UsdMicros
  eligible :: Bool
end

struct PerpEntry do
  opportunity :: OpportunitySet
  variant :: PaperVariant
  leg :: SpotLeg
  opening_perp :: PortfolioState
  spot_fill :: PaperFill
end

fn oracle_valid(status :: OracleStatus) -> Bool do
  case status do
    OracleValid -> true
    OracleInvalid -> false
  end
end

fn minimum_depth(spot :: Lamports, perp :: Lamports) -> Lamports do
  if spot.atoms < perp.atoms do
    spot
  else
    perp
  end
end

fn spot_leg(snapshot :: MarketSnapshot, opportunity :: OpportunitySet, variant :: PaperVariant) -> SpotLeg do
  case variant do
    SolControl -> SpotLeg {
      asset : "SOL",
      quantity : QuantityAtoms { atoms : opportunity.hedge_lamports.atoms },
      price : snapshot.sol_spot_ask_price_usd_micros,
      exit_depth : snapshot.sol_exit_depth_lamports,
      net_carry : opportunity.sol_net_carry_usd_micros,
      eligible : opportunity.sol_eligible
    }
    JitoSolCarry -> SpotLeg {
      asset : "JitoSOL",
      quantity : QuantityAtoms { atoms : snapshot.jitosol_atoms.atoms },
      price : snapshot.jitosol_spot_ask_price_usd_micros,
      exit_depth : snapshot.jitosol_exit_depth_lamports,
      net_carry : opportunity.jitosol_net_carry_usd_micros,
      eligible : opportunity.jitosol_eligible
    }
  end
end

fn emergency_after(state :: PortfolioState) -> PortfolioState ! String do
  state
    |> transition(Fault)
end

fn paper_order(side :: OrderSide,
quantity :: QuantityAtoms,
price :: PriceMicros,
snapshot :: MarketSnapshot,
fill_rate :: RatePpm,
fee :: RatePpm) -> PaperOrder do
  PaperOrder {
    side : side,
    quantity : quantity,
    quantity_scale : 1000000000,
    quoted_price : price,
    fill_rate : fill_rate,
    slippage_rate : snapshot.slippage_ppm,
    fee_rate : fee
  }
end

fn fill_rate_for_depth(
  required :: Lamports,
  available :: Lamports,
  configured :: RatePpm
) -> RatePpm ! String do
  if required.atoms <= 0 || available.atoms >= required.atoms do
    Ok(configured)
  else
    let depth_rate = (available.atoms
      |> Checked.mul_div(1000000, required.atoms, :floor)) ?
    Ok(RatePpm {
      atoms : if depth_rate < configured.atoms do depth_rate else configured.atoms end
    })
  end
end

fn no_fill() -> LegFill do
  LegFill {
    placed : false,
    status : Rejected,
    filled_quantity : QuantityAtoms { atoms : 0 },
    average_price : PriceMicros { atoms : 0 },
    gross_usd : UsdMicros { atoms : 0 },
    fee_usd : UsdMicros { atoms : 0 }
  }
end

fn placed_fill(fill :: PaperFill) -> LegFill do
  LegFill {
    placed : true,
    status : fill.status,
    filled_quantity : fill.filled_quantity,
    average_price : fill.average_price,
    gross_usd : fill.gross_usd,
    fee_usd : fill.fee_usd
  }
end

fn skipped_plan(variant :: PaperVariant, reason :: String, random_state :: Int) -> PaperPlan do
  PaperPlan {
    variant : variant,
    spot_asset : "",
    outcome : EntrySkipped,
    reason : reason,
    next_state : Idle,
    next_random_state : random_state,
    spot_fill : no_fill(),
    perp_fill : no_fill()
  }
end

fn plan_perp(snapshot :: MarketSnapshot, entry :: PerpEntry, random_state :: Int) -> PaperPlan ! String do
  let failure = sample_failure(random_state, snapshot.reject_rate_ppm, snapshot.unknown_rate_ppm) ?
  case failure.outcome do
    Reject -> do
      let emergency = emergency_after(entry.opening_perp) ?
      Ok(PaperPlan {
        variant : entry.variant,
        spot_asset : entry.leg.asset,
        outcome : EntryRejected,
        reason : "paper_perp_rejected",
        next_state : emergency,
        next_random_state : failure.random_state,
        spot_fill : placed_fill(entry.spot_fill),
        perp_fill : no_fill()
      })
    end
    Unknown -> do
      let emergency = emergency_after(entry.opening_perp) ?
      Ok(PaperPlan {
        variant : entry.variant,
        spot_asset : entry.leg.asset,
        outcome : EntryUnknown,
        reason : "paper_perp_unknown",
        next_state : emergency,
        next_random_state : failure.random_state,
        spot_fill : placed_fill(entry.spot_fill),
        perp_fill : no_fill()
      })
    end
    Continue -> do
      let order = paper_order(Sell,
      QuantityAtoms { atoms : entry.opportunity.hedge_lamports.atoms },
      snapshot.perp_bid_price_usd_micros,
      snapshot,
      snapshot.fill_rate_ppm,
      snapshot.perp_fee_ppm)
      let fill = simulate_fill(order) ?
      case fill.status do
        Filled -> do
          let hedged = transition(entry.opening_perp, PerpFilled) ?
          Ok(PaperPlan {
            variant : entry.variant,
            spot_asset : entry.leg.asset,
            outcome : EntryHedged,
            reason : "paper_entry_hedged",
            next_state : hedged,
            next_random_state : failure.random_state,
            spot_fill : placed_fill(entry.spot_fill),
            perp_fill : placed_fill(fill)
          })
        end
        Partial -> do
          let emergency = emergency_after(entry.opening_perp) ?
          Ok(PaperPlan {
            variant : entry.variant,
            spot_asset : entry.leg.asset,
            outcome : EntryPartial,
            reason : "paper_perp_partial",
            next_state : emergency,
            next_random_state : failure.random_state,
            spot_fill : placed_fill(entry.spot_fill),
            perp_fill : placed_fill(fill)
          })
        end
        Rejected -> do
          let emergency = emergency_after(entry.opening_perp) ?
          Ok(PaperPlan {
            variant : entry.variant,
            spot_asset : entry.leg.asset,
            outcome : EntryRejected,
            reason : "paper_perp_unfilled",
            next_state : emergency,
            next_random_state : failure.random_state,
            spot_fill : placed_fill(entry.spot_fill),
            perp_fill : placed_fill(fill)
          })
        end
      end
    end
  end
end

fn plan_spot(snapshot :: MarketSnapshot,
opportunity :: OpportunitySet,
variant :: PaperVariant,
leg :: SpotLeg,
opening_spot :: PortfolioState,
random_state :: Int) -> PaperPlan ! String do
  let failure = sample_failure(random_state, snapshot.reject_rate_ppm, snapshot.unknown_rate_ppm) ?
  case failure.outcome do
    Reject -> do
      let emergency = emergency_after(opening_spot) ?
      Ok(PaperPlan {
        variant : variant,
        spot_asset : leg.asset,
        outcome : EntryRejected,
        reason : "paper_spot_rejected",
        next_state : emergency,
        next_random_state : failure.random_state,
        spot_fill : no_fill(),
        perp_fill : no_fill()
      })
    end
    Unknown -> do
      let emergency = emergency_after(opening_spot) ?
      Ok(PaperPlan {
        variant : variant,
        spot_asset : leg.asset,
        outcome : EntryUnknown,
        reason : "paper_spot_unknown",
        next_state : emergency,
        next_random_state : failure.random_state,
        spot_fill : no_fill(),
        perp_fill : no_fill()
      })
    end
    Continue -> do
      let fill = simulate_fill(paper_order(Buy,
      leg.quantity,
      leg.price,
      snapshot,
      snapshot.fill_rate_ppm,
      snapshot.spot_fee_ppm)) ?
      case fill.status do
        Filled -> do
          let opening_perp = transition(opening_spot, SpotFilled) ?
          plan_perp(snapshot,
          PerpEntry {
            opportunity : opportunity,
            variant : variant,
            leg : leg,
            opening_perp : opening_perp,
            spot_fill : fill
          },
          failure.random_state)
        end
        Partial -> do
          let emergency = emergency_after(opening_spot) ?
          Ok(PaperPlan {
            variant : variant,
            spot_asset : leg.asset,
            outcome : EntryPartial,
            reason : "paper_spot_partial",
            next_state : emergency,
            next_random_state : failure.random_state,
            spot_fill : placed_fill(fill),
            perp_fill : no_fill()
          })
        end
        Rejected -> do
          let emergency = emergency_after(opening_spot) ?
          Ok(PaperPlan {
            variant : variant,
            spot_asset : leg.asset,
            outcome : EntryRejected,
            reason : "paper_spot_unfilled",
            next_state : emergency,
            next_random_state : failure.random_state,
            spot_fill : placed_fill(fill),
            perp_fill : no_fill()
          })
        end
      end
    end
  end
end

fn margin_input(snapshot :: MarketSnapshot, runtime :: PaperRuntime) -> MarginInput do
  MarginInput {
    collateral_usd_micros : snapshot.collateral_usd_micros,
    maintenance_requirement_usd_micros : snapshot.maintenance_requirement_usd_micros,
    minimum_margin_ratio_ppm : runtime.minimum_margin_ratio_ppm,
    liquidation_distance_bps : snapshot.liquidation_distance_bps,
    minimum_liquidation_distance_bps : runtime.minimum_liquidation_distance_bps
  }
end

pub fn plan_entry(snapshot :: MarketSnapshot,
opportunity :: OpportunitySet,
variant :: PaperVariant,
runtime :: PaperRuntime) -> PaperPlan ! String do
  let leg = spot_leg(snapshot, opportunity, variant)
  if runtime.state != Idle do
    return Ok(skipped_plan(variant, "portfolio_not_idle", runtime.random_state))
  end
  let decision = approve_entry(RiskInput {
    observed_at_ms : snapshot.observed_at_ms,
    now_ms : runtime.now_ms,
    max_age_ms : runtime.max_age_ms,
    paused : runtime.paused,
    oracle_valid : oracle_valid(snapshot.oracle_status),
    exit_depth : minimum_depth(leg.exit_depth, snapshot.perp_exit_depth_lamports),
    hedge : opportunity.hedge_lamports,
    net_carry : leg.net_carry,
    margin : margin_input(snapshot, runtime)
  })
  if decision.approved == false do
    return Ok(skipped_plan(variant, decision.code, runtime.random_state))
  end
  if leg.eligible == false do
    return Ok(skipped_plan(variant, "opportunity_ineligible", runtime.random_state))
  end
  let candidate = transition(Idle, OpportunityFound) ?
  let opening_spot = transition(candidate, OpenApproved) ?
  plan_spot(snapshot, opportunity, variant, leg, opening_spot, runtime.random_state)
end

fn position_market_rate(snapshot :: MarketSnapshot, variant :: PaperVariant) -> Lamports ! String do
  case variant do
    SolControl -> Ok(Lamports { atoms : 1000000000 })
    JitoSolCarry -> do
      let atoms = (snapshot.jitosol_spot_bid_price_usd_micros.atoms
        |> Checked.mul_div(1000000000, snapshot.sol_price_usd_micros.atoms, :floor)) ?
      Ok(Lamports { atoms : atoms })
    end
  end
end

fn position_nav(snapshot :: MarketSnapshot, opportunity :: OpportunitySet, variant :: PaperVariant) -> Lamports do
  case variant do
    SolControl -> Lamports { atoms : 1000000000 }
    JitoSolCarry -> opportunity.nav_lamports
  end
end

fn position_valuation(snapshot :: MarketSnapshot,
opportunity :: OpportunitySet,
position :: PaperPosition) -> PaperValuation ! String do
  let nav = position_nav(snapshot, opportunity, position.variant)
  let market_rate = position_market_rate(snapshot, position.variant) ?
  let exposure = (position.spot_quantity
    |> position_delta(market_rate, position.perp_short_quantity)) ?
  let nav_change = (nav.atoms
    |> Checked.sub(position.prior_nav_lamports.atoms)) ?
  let reward_atoms = (position.spot_quantity.atoms
    |> Checked.mul_div(nav_change, 1000000000, :half_even)) ?
  let prior_basis = (position.prior_market_rate_lamports.atoms
    |> Checked.sub(position.prior_nav_lamports.atoms)) ?
  let current_basis = (market_rate.atoms
    |> Checked.sub(nav.atoms)) ?
  let basis_change = (current_basis
    |> Checked.sub(prior_basis)) ?
  let basis_atoms = (position.spot_quantity.atoms
    |> Checked.mul_div(basis_change, 1000000000, :half_even)) ?
  Ok(PaperValuation {
    protocol_nav_lamports : nav,
    market_rate_lamports : market_rate,
    spot_equivalent_lamports : exposure.spot_equivalent_lamports,
    delta_lamports : exposure.delta_lamports,
    delta_bps : exposure.delta_bps,
    reward_sol_lamports : Lamports { atoms : reward_atoms },
    basis_sol_lamports : Lamports { atoms : basis_atoms }
  })
end

fn position_plan(action :: PaperAction,
reason :: String,
spot_asset :: String,
request :: PositionRequest,
next_state :: PortfolioState,
next_random_state :: Int,
next_spot_quantity :: TokenAtoms,
next_perp_short_quantity :: Lamports,
valuation :: PaperValuation,
spot_fill :: LegFill,
perp_fill :: LegFill) -> PositionPlan do
  PositionPlan {
    action : action,
    reason : reason,
    spot_asset : spot_asset,
    perp_side : request.perp_side,
    spot_requested_quantity : request.spot_quantity,
    perp_requested_quantity : request.perp_quantity,
    next_state : next_state,
    next_random_state : next_random_state,
    next_spot_quantity : next_spot_quantity,
    next_perp_short_quantity : next_perp_short_quantity,
    valuation : valuation,
    spot_fill : spot_fill,
    perp_fill : perp_fill
  }
end

fn emergency_position(reason :: String,
position :: PaperPosition,
valuation :: PaperValuation,
request :: PositionRequest,
next_random_state :: Int,
next_spot_quantity :: TokenAtoms,
next_perp_short_quantity :: Lamports,
spot_fill :: LegFill,
perp_fill :: LegFill) -> PositionPlan ! String do
  let emergency = transition(Hedged, Fault) ?
  Ok(position_plan(EmergencyPosition,
  reason,
  if position.variant == SolControl do "SOL" else "JitoSOL" end,
  request,
  emergency,
  next_random_state,
  next_spot_quantity,
  next_perp_short_quantity,
  valuation,
  spot_fill,
  perp_fill))
end

fn hold_position(
  position :: PaperPosition,
  valuation :: PaperValuation,
  reason :: String
) -> PositionPlan do
  position_plan(HoldPosition,
  reason,
  if position.variant == SolControl do "SOL" else "JitoSOL" end,
  PositionRequest {
    spot_quantity : TokenAtoms { atoms : 0 },
    perp_quantity : Lamports { atoms : 0 },
    perp_side : ""
  },
  Hedged,
  position.random_state,
  position.spot_quantity,
  position.perp_short_quantity,
  valuation,
  no_fill(),
  no_fill())
end

fn plan_rebalance(snapshot :: MarketSnapshot,
position :: PaperPosition,
valuation :: PaperValuation) -> PositionPlan ! String do
  let quantity_atoms = Checked.abs(valuation.delta_lamports.atoms) ?
  let side = if valuation.delta_lamports.atoms > 0 do Sell else Buy end
  let price = if side == Sell do
    snapshot.perp_bid_price_usd_micros
  else
    snapshot.perp_ask_price_usd_micros
  end
  let sampled = sample_failure(position.random_state, snapshot.reject_rate_ppm, snapshot.unknown_rate_ppm) ?
  let request = PositionRequest {
    spot_quantity : TokenAtoms { atoms : 0 },
    perp_quantity : Lamports { atoms : quantity_atoms },
    perp_side : if side == Sell do "SELL" else "BUY" end
  }
  if sampled.outcome != Continue do
    return emergency_position("paper_rebalance_unresolved",
    position,
    valuation,
    request,
    sampled.random_state,
    position.spot_quantity,
    position.perp_short_quantity,
    no_fill(),
    no_fill())
  end
  let fill = simulate_fill(paper_order(side,
  QuantityAtoms { atoms : quantity_atoms },
  price,
  snapshot,
  (Lamports { atoms : quantity_atoms }
    |> fill_rate_for_depth(snapshot.perp_exit_depth_lamports, snapshot.fill_rate_ppm)) ?,
  snapshot.perp_fee_ppm)) ?
  if fill.status != Filled do
    let next_perp_atoms = if side == Sell do
      (position.perp_short_quantity.atoms
        |> Checked.add(fill.filled_quantity.atoms)) ?
    else
      (position.perp_short_quantity.atoms
        |> Checked.sub(fill.filled_quantity.atoms)) ?
    end
    return emergency_position("paper_rebalance_partial",
    position,
    valuation,
    request,
    sampled.random_state,
    position.spot_quantity,
    Lamports { atoms : next_perp_atoms },
    no_fill(),
    placed_fill(fill))
  end
  let rebalancing = transition(Hedged, DeltaBreached) ?
  let hedged = transition(rebalancing, Rebalanced) ?
  Ok(position_plan(RebalancePerp,
  "paper_delta_rebalanced",
  if position.variant == SolControl do "SOL" else "JitoSOL" end,
  request,
  hedged,
  sampled.random_state,
  position.spot_quantity,
  valuation.spot_equivalent_lamports,
  valuation,
  no_fill(),
  placed_fill(fill)))
end

struct CloseContext do
  position :: PaperPosition
  valuation :: PaperValuation
  state :: PortfolioState
  action :: PaperAction
  reason :: String
  request :: PositionRequest
end

fn close_state(state :: PortfolioState) -> PortfolioState ! String do
  if state == Hedged do
    (((state |> transition(ExitRequired)) ?
      |> transition(PerpClosed)) ?
      |> transition(SpotClosed))
  else
    let emergency = if state == EmergencyFlatten do
      state
    else
      (state |> transition(Fault)) ?
    end
    ((emergency |> transition(ReconciledFlat)) ?
      |> transition(ReconciledFlat))
  end
end

fn unresolved_close(
  context :: CloseContext,
  reason :: String,
  random_state :: Int,
  next_spot :: TokenAtoms,
  next_perp :: Lamports,
  spot_fill :: LegFill,
  perp_fill :: LegFill
) -> PositionPlan ! String do
  let emergency = if context.state == EmergencyFlatten do
    context.state
  else
    (context.state |> transition(Fault)) ?
  end
  Ok(position_plan(
    if context.action == RecoverPosition do RecoverPosition else EmergencyPosition end,
    reason,
    if context.position.variant == SolControl do "SOL" else "JitoSOL" end,
    context.request,
    emergency,
    random_state,
    next_spot,
    next_perp,
    context.valuation,
    spot_fill,
    perp_fill
  ))
end

fn completed_close(
  context :: CloseContext,
  random_state :: Int,
  spot_fill :: LegFill,
  perp_fill :: LegFill
) -> PositionPlan ! String do
  Ok(position_plan(
    context.action,
    context.reason,
    if context.position.variant == SolControl do "SOL" else "JitoSOL" end,
    context.request,
    close_state(context.state) ?,
    random_state,
    TokenAtoms { atoms : 0 },
    Lamports { atoms : 0 },
    context.valuation,
    spot_fill,
    perp_fill
  ))
end

fn finish_spot_close(
  snapshot :: MarketSnapshot,
  context :: CloseContext,
  random_state :: Int,
  perp_fill :: LegFill
) -> PositionPlan ! String do
  if context.position.spot_quantity.atoms == 0 do
    return completed_close(context, random_state, no_fill(), perp_fill)
  end
  let sampled = sample_failure(random_state, snapshot.reject_rate_ppm, snapshot.unknown_rate_ppm) ?
  if sampled.outcome != Continue do
    return unresolved_close(
      context,
      "paper_spot_close_unresolved",
      sampled.random_state,
      context.position.spot_quantity,
      Lamports { atoms : 0 },
      no_fill(),
      perp_fill
    )
  end
  let spot_price = if context.position.variant == SolControl do
    snapshot.sol_spot_bid_price_usd_micros
  else
    snapshot.jitosol_spot_bid_price_usd_micros
  end
  let exit_depth = if context.position.variant == SolControl do
    snapshot.sol_exit_depth_lamports
  else
    snapshot.jitosol_exit_depth_lamports
  end
  let fill = simulate_fill(paper_order(
    Sell,
    QuantityAtoms { atoms : context.position.spot_quantity.atoms },
    spot_price,
    snapshot,
    (context.valuation.spot_equivalent_lamports
      |> fill_rate_for_depth(exit_depth, snapshot.fill_rate_ppm)) ?,
    snapshot.spot_fee_ppm
  )) ?
  if fill.status == Filled do
    completed_close(context, sampled.random_state, placed_fill(fill), perp_fill)
  else
    unresolved_close(
      context,
      "paper_spot_close_partial",
      sampled.random_state,
      TokenAtoms {
        atoms : (context.position.spot_quantity.atoms
          |> Checked.sub(fill.filled_quantity.atoms)) ?
      },
      Lamports { atoms : 0 },
      placed_fill(fill),
      perp_fill
    )
  end
end

fn plan_close(
  snapshot :: MarketSnapshot,
  position :: PaperPosition,
  valuation :: PaperValuation,
  state :: PortfolioState,
  action :: PaperAction,
  reason :: String
) -> PositionPlan ! String do
  let context = CloseContext {
    position : position,
    valuation : valuation,
    state : state,
    action : action,
    reason : reason,
    request : PositionRequest {
      spot_quantity : position.spot_quantity,
      perp_quantity : position.perp_short_quantity,
      perp_side : "BUY"
    }
  }
  if position.perp_short_quantity.atoms == 0 do
    return finish_spot_close(snapshot, context, position.random_state, no_fill())
  end
  let sampled = sample_failure(position.random_state, snapshot.reject_rate_ppm, snapshot.unknown_rate_ppm) ?
  if sampled.outcome != Continue do
    return unresolved_close(
      context,
      "paper_perp_close_unresolved",
      sampled.random_state,
      position.spot_quantity,
      position.perp_short_quantity,
      no_fill(),
      no_fill()
    )
  end
  let fill = simulate_fill(paper_order(
    Buy,
    QuantityAtoms { atoms : position.perp_short_quantity.atoms },
    snapshot.perp_ask_price_usd_micros,
    snapshot,
    (position.perp_short_quantity
      |> fill_rate_for_depth(snapshot.perp_exit_depth_lamports, snapshot.fill_rate_ppm)) ?,
    snapshot.perp_fee_ppm
  )) ?
  if fill.status == Filled do
    finish_spot_close(snapshot, context, sampled.random_state, placed_fill(fill))
  else
    unresolved_close(
      context,
      "paper_perp_close_partial",
      sampled.random_state,
      position.spot_quantity,
      Lamports {
        atoms : (position.perp_short_quantity.atoms
          |> Checked.sub(fill.filled_quantity.atoms)) ?
      },
      no_fill(),
      placed_fill(fill)
    )
  end
end

fn plan_exit(
  snapshot :: MarketSnapshot,
  position :: PaperPosition,
  valuation :: PaperValuation,
  reason :: String
) -> PositionPlan ! String do
  plan_close(snapshot, position, valuation, Hedged, ExitPosition, reason)
end

pub fn plan_recovery(
  snapshot :: MarketSnapshot,
  opportunity :: OpportunitySet,
  position :: PaperPosition,
  state :: PortfolioState
) -> PositionPlan ! String do
  if state != OpeningSpot && state != OpeningPerp && state != EmergencyFlatten do
    return Err("paper recovery requires a transitional or emergency state")
  end
  plan_close(
    snapshot,
    position,
    position_valuation(snapshot, opportunity, position) ?,
    state,
    RecoverPosition,
    "paper_exposure_recovered"
  )
end

pub fn plan_forced_exit(snapshot :: MarketSnapshot,
opportunity :: OpportunitySet,
position :: PaperPosition,
reason :: String) -> PositionPlan ! String do
  if String.length(String.trim(reason)) == 0 do
    return Err("paper exit reason is required")
  end
  plan_exit(snapshot, position, position_valuation(snapshot, opportunity, position) ?, reason)
end

pub fn plan_position(snapshot :: MarketSnapshot,
opportunity :: OpportunitySet,
position :: PaperPosition,
runtime :: PaperRuntime) -> PositionPlan ! String do
  if runtime.rebalance_delta_bps < 0 do
    return Err("rebalance delta threshold must be non-negative")
  end
  let valuation = position_valuation(snapshot, opportunity, position) ?
  let source = snapshot.observed_at_ms
    |> source_health(runtime.now_ms, runtime.max_age_ms)
  if source.approved == false do
    return Ok(hold_position(position, valuation, source.code))
  end
  let margin = margin_input(snapshot, runtime) |> margin_health
  if margin.approved == false do
    return plan_exit(snapshot, position, valuation, margin.code)
  end
  let net_carry = if position.variant == SolControl do
    opportunity.sol_net_carry_usd_micros
  else
    opportunity.jitosol_net_carry_usd_micros
  end
  if oracle_valid(snapshot.oracle_status) == false do
    return plan_exit(snapshot, position, valuation, "oracle_invalid")
  end
  let spot_exit_depth = if position.variant == SolControl do
    snapshot.sol_exit_depth_lamports
  else
    snapshot.jitosol_exit_depth_lamports
  end
  if spot_exit_depth.atoms < valuation.spot_equivalent_lamports.atoms || snapshot.perp_exit_depth_lamports.atoms < position.perp_short_quantity.atoms do
    return plan_exit(snapshot, position, valuation, "exit_depth_insufficient")
  end
  if net_carry.atoms <= 0 do
    return plan_exit(snapshot, position, valuation, "carry_non_positive")
  end
  if valuation.delta_bps >= runtime.rebalance_delta_bps && valuation.delta_lamports.atoms != 0 do
    plan_rebalance(snapshot, position, valuation)
  else
    Ok(hold_position(position, valuation, "within_delta_band"))
  end
end
