from Packages.Finance import Lamports, UsdMicros
from Packages.ProtocolContracts import MarketSnapshot
from Packages.StrategyCore import break_even_within_hours, executable_hedge_lamports, expected_funding_usd_micros, is_entry_eligible, jitosol_nav_lamports, nav_reward_lamports, projected_net_carry_usd_micros

pub struct OpportunitySet do
  nav_lamports :: Lamports
  hedge_lamports :: Lamports
  expected_funding_usd_micros :: UsdMicros
  nav_reward_lamports :: Lamports
  nav_reward_usd_micros :: UsdMicros
  sol_net_carry_usd_micros :: UsdMicros
  jitosol_net_carry_usd_micros :: UsdMicros
  sol_eligible :: Bool
  jitosol_eligible :: Bool
end deriving(Json)

pub fn evaluate_snapshot(snapshot :: MarketSnapshot) -> OpportunitySet ! String do
  evaluate_snapshot_for_horizon(snapshot, 72, 48)
end

pub fn evaluate_snapshot_for_horizon(
  snapshot :: MarketSnapshot,
  expected_hold_hours :: Int,
  maximum_break_even_hours :: Int
) -> OpportunitySet ! String do
  let nav = jitosol_nav_lamports(snapshot.total_pool_lamports, snapshot.supply_atoms) ?
  let hedge = executable_hedge_lamports(snapshot.jitosol_atoms, snapshot.jitosol_spot_bid_price_usd_micros, snapshot.sol_price_usd_micros) ?
  let hourly_funding = expected_funding_usd_micros(snapshot.notional_usd_micros, snapshot.short_receipt_ppm) ?
  let hourly_reward = expected_funding_usd_micros(snapshot.notional_usd_micros, snapshot.reward_rate_ppm_per_hour) ?
  let funding = projected_net_carry_usd_micros(
    hourly_funding,
    UsdMicros { atoms : 0 },
    UsdMicros { atoms : 0 },
    UsdMicros { atoms : 0 },
    expected_hold_hours
  ) ?
  let reward_lamports = nav_reward_lamports(snapshot.jitosol_atoms, nav, snapshot.prior_nav_lamports) ?
  let reward_usd = projected_net_carry_usd_micros(
    UsdMicros { atoms : 0 },
    hourly_reward,
    UsdMicros { atoms : 0 },
    UsdMicros { atoms : 0 },
    expected_hold_hours
  ) ?
  let sol_net = projected_net_carry_usd_micros(
    hourly_funding,
    UsdMicros { atoms : 0 },
    snapshot.costs_usd_micros,
    snapshot.risk_haircut_usd_micros,
    expected_hold_hours
  ) ?
  let jitosol_net = projected_net_carry_usd_micros(
    hourly_funding,
    hourly_reward,
    snapshot.costs_usd_micros,
    snapshot.risk_haircut_usd_micros,
    expected_hold_hours
  ) ?
  let sol_breaks_even = break_even_within_hours(
    hourly_funding,
    UsdMicros { atoms : 0 },
    snapshot.costs_usd_micros,
    snapshot.risk_haircut_usd_micros,
    maximum_break_even_hours
  ) ?
  let jitosol_breaks_even = break_even_within_hours(
    hourly_funding,
    hourly_reward,
    snapshot.costs_usd_micros,
    snapshot.risk_haircut_usd_micros,
    maximum_break_even_hours
  ) ?
  Ok(OpportunitySet {
    nav_lamports : nav,
    hedge_lamports : hedge,
    expected_funding_usd_micros : funding,
    nav_reward_lamports : reward_lamports,
    nav_reward_usd_micros : reward_usd,
    sol_net_carry_usd_micros : sol_net,
    jitosol_net_carry_usd_micros : jitosol_net,
    sol_eligible : is_entry_eligible(snapshot.short_receipt_ppm, sol_net) && sol_breaks_even,
    jitosol_eligible : is_entry_eligible(snapshot.short_receipt_ppm, jitosol_net) && jitosol_breaks_even
  })
end
