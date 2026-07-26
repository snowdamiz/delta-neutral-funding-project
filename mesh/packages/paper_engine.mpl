from Packages.BrokerPaper import FailureOutcome, FillStatus, OrderSide, PaperFill, PaperOrder, sample_failure, simulate_fill
from Packages.Finance import Lamports, PriceMicros, QuantityAtoms, RatePpm, UsdMicros
from Packages.Opportunity import OpportunitySet
from Packages.ProtocolContracts import MarketSnapshot, OracleStatus
from Packages.RiskEngine import RiskInput, approve_entry
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
  state :: PortfolioState
  state_version :: Int
  random_state :: Int
end

pub type PaperAction do
  HoldPosition

  RebalancePerp

  ExitPosition

  EmergencyPosition
end deriving(Eq, Display, Json)

pub fn action_name(action :: PaperAction) -> String do
  case action do
    HoldPosition -> "hold"
    RebalancePerp -> "rebalance_perp"
    ExitPosition -> "exit"
    EmergencyPosition -> "emergency"
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
  next_state :: PortfolioState
  next_random_state :: Int
  next_perp_short_quantity :: Lamports
  valuation :: PaperValuation
  spot_fill :: LegFill
  perp_fill :: LegFill
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
fee :: RatePpm) -> PaperOrder do
  PaperOrder {
    side : side,
    quantity : quantity,
    quantity_scale : 1000000000,
    quoted_price : price,
    fill_rate : snapshot.fill_rate_ppm,
    slippage_rate : snapshot.slippage_ppm,
    fee_rate : fee
  }
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
        Partial -> Ok(PaperPlan {
          variant : entry.variant,
          spot_asset : entry.leg.asset,
          outcome : EntryPartial,
          reason : "paper_perp_partial",
          next_state : entry.opening_perp,
          next_random_state : failure.random_state,
          spot_fill : placed_fill(entry.spot_fill),
          perp_fill : placed_fill(fill)
        })
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
        Partial -> Ok(PaperPlan {
          variant : variant,
          spot_asset : leg.asset,
          outcome : EntryPartial,
          reason : "paper_spot_partial",
          next_state : opening_spot,
          next_random_state : failure.random_state,
          spot_fill : placed_fill(fill),
          perp_fill : no_fill()
        })
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
    net_carry : leg.net_carry
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
  let spot_equivalent_atoms = (position.spot_quantity.atoms
    |> Checked.mul_div(market_rate.atoms, 1000000000, :floor)) ?
  let delta_atoms = (spot_equivalent_atoms
    |> Checked.sub(position.perp_short_quantity.atoms)) ?
  let absolute_delta = Checked.abs(delta_atoms) ?
  let delta_bps = if spot_equivalent_atoms == 0 do
    0
  else
    (absolute_delta
      |> Checked.mul_div(10000, spot_equivalent_atoms, :ceil)) ?
  end
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
    spot_equivalent_lamports : Lamports { atoms : spot_equivalent_atoms },
    delta_lamports : Lamports { atoms : delta_atoms },
    delta_bps : delta_bps,
    reward_sol_lamports : Lamports { atoms : reward_atoms },
    basis_sol_lamports : Lamports { atoms : basis_atoms }
  })
end

fn position_plan(action :: PaperAction,
reason :: String,
spot_asset :: String,
perp_side :: String,
next_state :: PortfolioState,
next_random_state :: Int,
next_perp_short_quantity :: Lamports,
valuation :: PaperValuation,
spot_fill :: LegFill,
perp_fill :: LegFill) -> PositionPlan do
  PositionPlan {
    action : action,
    reason : reason,
    spot_asset : spot_asset,
    perp_side : perp_side,
    next_state : next_state,
    next_random_state : next_random_state,
    next_perp_short_quantity : next_perp_short_quantity,
    valuation : valuation,
    spot_fill : spot_fill,
    perp_fill : perp_fill
  }
end

fn emergency_position(reason :: String,
position :: PaperPosition,
valuation :: PaperValuation,
next_random_state :: Int,
spot_fill :: LegFill,
perp_fill :: LegFill) -> PositionPlan ! String do
  let emergency = transition(Hedged, Fault) ?
  Ok(position_plan(EmergencyPosition,
  reason,
  if position.variant == SolControl do "SOL" else "JitoSOL" end,
  "",
  emergency,
  next_random_state,
  position.perp_short_quantity,
  valuation,
  spot_fill,
  perp_fill))
end

fn hold_position(position :: PaperPosition, valuation :: PaperValuation) -> PositionPlan do
  position_plan(HoldPosition,
  "within_delta_band",
  if position.variant == SolControl do "SOL" else "JitoSOL" end,
  "",
  Hedged,
  position.random_state,
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
  if sampled.outcome != Continue do
    return emergency_position("paper_rebalance_unresolved",
    position,
    valuation,
    sampled.random_state,
    no_fill(),
    no_fill())
  end
  let fill = simulate_fill(paper_order(side,
  QuantityAtoms { atoms : quantity_atoms },
  price,
  snapshot,
  snapshot.perp_fee_ppm)) ?
  if fill.status != Filled do
    return emergency_position("paper_rebalance_partial",
    position,
    valuation,
    sampled.random_state,
    no_fill(),
    placed_fill(fill))
  end
  let rebalancing = transition(Hedged, DeltaBreached) ?
  let hedged = transition(rebalancing, Rebalanced) ?
  Ok(position_plan(RebalancePerp,
  "paper_delta_rebalanced",
  if position.variant == SolControl do "SOL" else "JitoSOL" end,
  if side == Sell do "SELL" else "BUY" end,
  hedged,
  sampled.random_state,
  valuation.spot_equivalent_lamports,
  valuation,
  no_fill(),
  placed_fill(fill)))
end

fn plan_exit(snapshot :: MarketSnapshot,
position :: PaperPosition,
valuation :: PaperValuation,
reason :: String) -> PositionPlan ! String do
  let perp_sample = sample_failure(position.random_state, snapshot.reject_rate_ppm, snapshot.unknown_rate_ppm) ?
  if perp_sample.outcome != Continue do
    return emergency_position("paper_perp_close_unresolved",
    position,
    valuation,
    perp_sample.random_state,
    no_fill(),
    no_fill())
  end
  let perp_fill = simulate_fill(paper_order(Buy,
  QuantityAtoms { atoms : position.perp_short_quantity.atoms },
  snapshot.perp_ask_price_usd_micros,
  snapshot,
  snapshot.perp_fee_ppm)) ?
  if perp_fill.status != Filled do
    return emergency_position("paper_perp_close_partial",
    position,
    valuation,
    perp_sample.random_state,
    no_fill(),
    placed_fill(perp_fill))
  end
  let spot_sample = sample_failure(perp_sample.random_state, snapshot.reject_rate_ppm, snapshot.unknown_rate_ppm) ?
  if spot_sample.outcome != Continue do
    return emergency_position("paper_spot_close_unresolved",
    position,
    valuation,
    spot_sample.random_state,
    no_fill(),
    placed_fill(perp_fill))
  end
  let spot_price = if position.variant == SolControl do
    snapshot.sol_spot_bid_price_usd_micros
  else
    snapshot.jitosol_spot_bid_price_usd_micros
  end
  let spot_fill = simulate_fill(paper_order(Sell,
  QuantityAtoms { atoms : position.spot_quantity.atoms },
  spot_price,
  snapshot,
  snapshot.spot_fee_ppm)) ?
  if spot_fill.status != Filled do
    return emergency_position("paper_spot_close_partial",
    position,
    valuation,
    spot_sample.random_state,
    placed_fill(spot_fill),
    placed_fill(perp_fill))
  end
  let exiting_perp = transition(Hedged, ExitRequired) ?
  let exiting_spot = transition(exiting_perp, PerpClosed) ?
  let idle = transition(exiting_spot, SpotClosed) ?
  Ok(position_plan(ExitPosition,
  reason,
  if position.variant == SolControl do "SOL" else "JitoSOL" end,
  "BUY",
  idle,
  spot_sample.random_state,
  Lamports { atoms : 0 },
  valuation,
  placed_fill(spot_fill),
  placed_fill(perp_fill)))
end

pub fn plan_position(snapshot :: MarketSnapshot,
opportunity :: OpportunitySet,
position :: PaperPosition,
rebalance_delta_bps :: Int) -> PositionPlan ! String do
  if rebalance_delta_bps < 0 do
    return Err("rebalance delta threshold must be non-negative")
  end
  let valuation = position_valuation(snapshot, opportunity, position) ?
  let net_carry = if position.variant == SolControl do
    opportunity.sol_net_carry_usd_micros
  else
    opportunity.jitosol_net_carry_usd_micros
  end
  if oracle_valid(snapshot.oracle_status) == false do
    return plan_exit(snapshot, position, valuation, "oracle_invalid")
  end
  if net_carry.atoms <= 0 do
    return plan_exit(snapshot, position, valuation, "carry_non_positive")
  end
  if valuation.delta_bps >= rebalance_delta_bps && valuation.delta_lamports.atoms != 0 do
    plan_rebalance(snapshot, position, valuation)
  else
    Ok(hold_position(position, valuation))
  end
end
