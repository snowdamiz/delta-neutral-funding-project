from Packages.ProtocolContracts import MarketSnapshot
from Packages.StrategyCore import expected_funding_usd_micros, hedge_lamports, is_entry_eligible, jitosol_nav_lamports, nav_reward_lamports, net_carry_usd_micros

pub struct OpportunitySet do
  nav_lamports :: Int
  hedge_lamports :: Int
  expected_funding_usd_micros :: Int
  nav_reward_lamports :: Int
  nav_reward_usd_micros :: Int
  sol_net_carry_usd_micros :: Int
  jitosol_net_carry_usd_micros :: Int
  sol_eligible :: Bool
  jitosol_eligible :: Bool
end deriving(Json)

pub fn evaluate_snapshot(snapshot :: MarketSnapshot) -> OpportunitySet ! String do
  let nav = jitosol_nav_lamports(snapshot.total_pool_lamports, snapshot.supply_atoms) ?
  let hedge = hedge_lamports(snapshot.jitosol_atoms, nav) ?
  let funding = expected_funding_usd_micros(snapshot.notional_usd_micros, snapshot.short_receipt_ppm) ?
  let reward_lamports = nav_reward_lamports(snapshot.jitosol_atoms, nav, snapshot.prior_nav_lamports) ?
  let reward_usd = Checked.mul_div(reward_lamports, snapshot.sol_price_usd_micros, 1000000000, :floor) ?
  let sol_net = net_carry_usd_micros(funding, 0, snapshot.costs_usd_micros, snapshot.risk_haircut_usd_micros) ?
  let jitosol_net = net_carry_usd_micros(funding, reward_usd, snapshot.costs_usd_micros, snapshot.risk_haircut_usd_micros) ?
  Ok(OpportunitySet {
    nav_lamports : nav,
    hedge_lamports : hedge,
    expected_funding_usd_micros : funding,
    nav_reward_lamports : reward_lamports,
    nav_reward_usd_micros : reward_usd,
    sol_net_carry_usd_micros : sol_net,
    jitosol_net_carry_usd_micros : jitosol_net,
    sol_eligible : is_entry_eligible(snapshot.short_receipt_ppm, sol_net),
    jitosol_eligible : is_entry_eligible(snapshot.short_receipt_ppm, jitosol_net)
  })
end
