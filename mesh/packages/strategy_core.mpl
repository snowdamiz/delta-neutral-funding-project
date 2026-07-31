from Packages.Finance import Lamports, PriceMicros, RatePpm, TokenAtoms, UsdMicros, apply_rate, lamports_ratio, lamports_to_usd, token_value_lamports, usd_add, usd_sub

pub fn jitosol_nav_lamports(total_pool_lamports :: Lamports, supply_atoms :: TokenAtoms) -> Lamports ! String do
  total_pool_lamports |> lamports_ratio(supply_atoms, :floor)
end

pub fn hedge_lamports(jitosol_atoms :: TokenAtoms, nav_lamports_per_token :: Lamports) -> Lamports ! String do
  jitosol_atoms |> token_value_lamports(nav_lamports_per_token, :half_even)
end

pub fn executable_hedge_lamports(jitosol_atoms :: TokenAtoms, jitosol_sell_price :: PriceMicros, sol_price :: UsdMicros) -> Lamports ! String do
  let market_rate = (jitosol_sell_price.atoms
    |> Checked.mul_div(1000000000, sol_price.atoms, :floor)) ?
  jitosol_atoms
    |> token_value_lamports(Lamports { atoms : market_rate }, :floor)
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
  (((usd_add(funding, reward)) ?
    |> usd_sub(costs)) ?
    |> usd_sub(risk_haircut))
end

pub fn projected_net_carry_usd_micros(
  hourly_funding :: UsdMicros,
  hourly_reward :: UsdMicros,
  costs :: UsdMicros,
  risk_haircut :: UsdMicros,
  expected_hold_hours :: Int
) -> UsdMicros ! String do
  if expected_hold_hours <= 0 do
    return Err("expected hold hours must be positive")
  end
  let hourly_income = usd_add(hourly_funding, hourly_reward) ?
  let projected_income = Checked.mul(
    hourly_income.atoms,
    expected_hold_hours
  ) ?
  net_carry_usd_micros(
    UsdMicros { atoms : projected_income },
    UsdMicros { atoms : 0 },
    costs,
    risk_haircut
  )
end

pub fn break_even_within_hours(
  hourly_funding :: UsdMicros,
  hourly_reward :: UsdMicros,
  costs :: UsdMicros,
  risk_haircut :: UsdMicros,
  maximum_hours :: Int
) -> Bool ! String do
  if maximum_hours <= 0 do
    return Err("maximum break-even hours must be positive")
  end
  let hourly_income = usd_add(hourly_funding, hourly_reward) ?
  if hourly_income.atoms <= 0 do
    return Ok(false)
  end
  let maximum_income = Checked.mul(hourly_income.atoms, maximum_hours) ?
  let required_income = usd_add(costs, risk_haircut) ?
  Ok(maximum_income >= required_income.atoms)
end

pub fn is_entry_eligible(short_receipt_ppm :: RatePpm, net_carry_usd_micros :: UsdMicros) -> Bool do
  short_receipt_ppm.atoms > 0 && net_carry_usd_micros.atoms > 0
end
