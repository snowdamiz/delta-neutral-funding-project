from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros, apply_rate, lamports_ratio, lamports_to_usd, token_value_lamports, usd_add, usd_sub

pub fn jitosol_nav_lamports(total_pool_lamports :: Lamports, supply_atoms :: TokenAtoms) -> Lamports ! String do
  total_pool_lamports |> lamports_ratio(supply_atoms, :floor)
end

pub fn hedge_lamports(jitosol_atoms :: TokenAtoms, nav_lamports_per_token :: Lamports) -> Lamports ! String do
  jitosol_atoms |> token_value_lamports(nav_lamports_per_token, :half_even)
end

pub fn expected_funding_usd_micros(notional_usd_micros :: UsdMicros, short_receipt_ppm :: RatePpm) -> UsdMicros ! String do
  notional_usd_micros |> apply_rate(short_receipt_ppm, :toward_zero)
end

pub fn nav_reward_lamports(jitosol_atoms :: TokenAtoms, current_nav :: Lamports, prior_nav :: Lamports) -> Lamports ! String do
  if current_nav.atoms < prior_nav.atoms do
    Err("JitoSOL NAV decreased")
  else
    let nav_change_atoms = Checked.sub(current_nav.atoms, prior_nav.atoms) ?
    jitosol_atoms |> token_value_lamports(Lamports { atoms : nav_change_atoms }, :floor)
  end
end

pub fn reward_usd_micros(reward :: Lamports, sol_price :: UsdMicros) -> UsdMicros ! String do
  reward |> lamports_to_usd(sol_price, :floor)
end

pub fn net_carry_usd_micros(funding :: UsdMicros, reward :: UsdMicros, costs :: UsdMicros, risk_haircut :: UsdMicros) -> UsdMicros ! String do
  let gross = usd_add(funding, reward) ?
  let after_costs = usd_sub(gross, costs) ?
  after_costs |> usd_sub(risk_haircut)
end

pub fn is_entry_eligible(short_receipt_ppm :: RatePpm, net_carry_usd_micros :: UsdMicros) -> Bool do
  short_receipt_ppm.atoms > 0 && net_carry_usd_micros.atoms > 0
end
