pub fn jitosol_nav_lamports(total_pool_lamports :: Int, supply_atoms :: Int) -> Int ! String do
  Checked.mul_div(total_pool_lamports, 1000000000, supply_atoms, :floor)
end

pub fn hedge_lamports(jitosol_atoms :: Int, nav_lamports_per_token :: Int) -> Int ! String do
  Checked.mul_div(jitosol_atoms, nav_lamports_per_token, 1000000000, :half_even)
end

pub fn expected_funding_usd_micros(notional_usd_micros :: Int, short_receipt_ppm :: Int) -> Int ! String do
  Checked.mul_div(notional_usd_micros, short_receipt_ppm, 1000000, :toward_zero)
end

pub fn nav_reward_lamports(jitosol_atoms :: Int, current_nav :: Int, prior_nav :: Int) -> Int ! String do
  if current_nav < prior_nav do
    Err("JitoSOL NAV decreased")
  else
    let nav_change = Checked.sub(current_nav, prior_nav) ?
    Checked.mul_div(jitosol_atoms, nav_change, 1000000000, :floor)
  end
end

pub fn net_carry_usd_micros(funding :: Int, reward :: Int, costs :: Int, risk_haircut :: Int) -> Int ! String do
  let gross = Checked.add(funding, reward) ?
  let after_costs = Checked.sub(gross, costs) ?
  Checked.sub(after_costs, risk_haircut)
end

pub fn is_entry_eligible(short_receipt_ppm :: Int, net_carry_usd_micros :: Int) -> Bool do
  short_receipt_ppm > 0 && net_carry_usd_micros > 0
end
