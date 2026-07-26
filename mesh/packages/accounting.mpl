from Packages.Finance import Lamports, RatePpm, TokenAtoms, UsdMicros, apply_rate, lamports_to_usd, token_value_lamports, usd_add, usd_sub

pub type DirectUnstakeState do
  Requested
  Deactivating
  WaitingForEpoch
  Withdrawable
  Withdrawn
  Failed
end deriving(Eq, Display, Json)

pub struct DirectUnstakeProjection do
  protocol_redemption_lamports :: Lamports
  withdrawal_fee_lamports :: Lamports
  net_redemption_lamports :: Lamports
  protocol_redemption_usd_micros :: UsdMicros
  withdrawal_fee_usd_micros :: UsdMicros
  cooldown_funding_usd_micros :: UsdMicros
  chain_fees_usd_micros :: UsdMicros
  hedge_cost_usd_micros :: UsdMicros
  capital_delay_haircut_usd_micros :: UsdMicros
  final_hedge_close_cost_usd_micros :: UsdMicros
  net_usd_micros :: UsdMicros
end deriving(Json)

pub struct DirectUnstakeProcess do
  state :: DirectUnstakeState
  requested_epoch :: Int
  available_epoch :: Int
  projection :: DirectUnstakeProjection
end deriving(Json)

fn with_direct_unstake_state(
  process :: DirectUnstakeProcess,
  state :: DirectUnstakeState
) -> DirectUnstakeProcess do
  DirectUnstakeProcess {
    state : state,
    requested_epoch : process.requested_epoch,
    available_epoch : process.available_epoch,
    projection : process.projection
  }
end

pub fn record_direct_unstake_funding(
  process :: DirectUnstakeProcess,
  funding :: UsdMicros
) -> DirectUnstakeProcess ! String do
  let projection = process.projection
  Ok(DirectUnstakeProcess {
    state : process.state,
    requested_epoch : process.requested_epoch,
    available_epoch : process.available_epoch,
    projection : DirectUnstakeProjection {
      protocol_redemption_lamports : projection.protocol_redemption_lamports,
      withdrawal_fee_lamports : projection.withdrawal_fee_lamports,
      net_redemption_lamports : projection.net_redemption_lamports,
      protocol_redemption_usd_micros : projection.protocol_redemption_usd_micros,
      withdrawal_fee_usd_micros : projection.withdrawal_fee_usd_micros,
      cooldown_funding_usd_micros : (projection.cooldown_funding_usd_micros
        |> usd_add(funding)) ?,
      chain_fees_usd_micros : projection.chain_fees_usd_micros,
      hedge_cost_usd_micros : projection.hedge_cost_usd_micros,
      capital_delay_haircut_usd_micros : projection.capital_delay_haircut_usd_micros,
      final_hedge_close_cost_usd_micros : projection.final_hedge_close_cost_usd_micros,
      net_usd_micros : (projection.net_usd_micros
        |> usd_add(funding)) ?
    }
  })
end

pub fn realized_funding_usd(
  perp_short_quantity :: Lamports,
  sol_price :: UsdMicros,
  realized_short_rate :: RatePpm
) -> UsdMicros ! String do
  let notional = (perp_short_quantity
    |> lamports_to_usd(sol_price, :half_even)) ?
  notional
    |> apply_rate(realized_short_rate, :toward_zero)
end

fn validate_direct_unstake(
  jitosol_quantity :: TokenAtoms,
  nav_lamports :: Lamports,
  sol_price :: UsdMicros,
  perp_short_quantity :: Lamports,
  realized_short_rate :: RatePpm,
  current_epoch :: Int,
  withdrawal_fee_rate :: RatePpm,
  chain_fees :: UsdMicros,
  cooldown_intervals :: Int,
  hedge_cost :: UsdMicros,
  capital_delay_haircut :: UsdMicros,
  final_hedge_close_cost :: UsdMicros
) -> TokenAtoms ! String do
  if jitosol_quantity.atoms <= 0 || nav_lamports.atoms <= 0 || sol_price.atoms <= 0 || perp_short_quantity.atoms < 0 do
    return Err("direct unstake quantities, NAV, or price are invalid")
  end
  if realized_short_rate.atoms < -1000000 || realized_short_rate.atoms > 1000000 do
    return Err("direct unstake funding rate must be between negative and positive one million ppm")
  end
  if current_epoch < 0 || cooldown_intervals < 0 do
    return Err("direct unstake epoch and cooldown must be non-negative")
  end
  if withdrawal_fee_rate.atoms < 0 || withdrawal_fee_rate.atoms > 1000000 do
    return Err("direct unstake withdrawal fee must be between zero and one million ppm")
  end
  if chain_fees.atoms < 0 || hedge_cost.atoms < 0 || capital_delay_haircut.atoms < 0 || final_hedge_close_cost.atoms < 0 do
    return Err("direct unstake costs must be non-negative")
  end
  Ok(jitosol_quantity)
end

pub fn start_direct_unstake(
  jitosol_quantity :: TokenAtoms,
  nav_lamports :: Lamports,
  sol_price :: UsdMicros,
  perp_short_quantity :: Lamports,
  realized_short_rate :: RatePpm,
  current_epoch :: Int,
  withdrawal_fee_rate :: RatePpm,
  chain_fees :: UsdMicros,
  cooldown_intervals :: Int,
  hedge_cost :: UsdMicros,
  capital_delay_haircut :: UsdMicros,
  final_hedge_close_cost :: UsdMicros
) -> DirectUnstakeProcess ! String do
  let validated_quantity = validate_direct_unstake(
    jitosol_quantity,
    nav_lamports,
    sol_price,
    perp_short_quantity,
    realized_short_rate,
    current_epoch,
    withdrawal_fee_rate,
    chain_fees,
    cooldown_intervals,
    hedge_cost,
    capital_delay_haircut,
    final_hedge_close_cost
  ) ?

  let protocol_redemption = (validated_quantity
    |> token_value_lamports(nav_lamports, :floor)) ?
  let withdrawal_fee = (protocol_redemption.atoms
    |> Checked.mul_div(withdrawal_fee_rate.atoms, 1000000, :ceil)) ?
  let net_redemption = (protocol_redemption.atoms
    |> Checked.sub(withdrawal_fee)) ?
  let protocol_redemption_usd = (protocol_redemption
    |> lamports_to_usd(sol_price, :toward_zero)) ?
  let withdrawal_fee_usd = (Lamports { atoms : withdrawal_fee }
    |> lamports_to_usd(sol_price, :toward_zero)) ?
  let net_redemption_usd = (protocol_redemption_usd
    |> usd_sub(withdrawal_fee_usd)) ?
  let cooldown_funding = ((perp_short_quantity
    |> realized_funding_usd(sol_price, realized_short_rate)) ?.atoms
    |> Checked.mul(cooldown_intervals)) ?
  let net_usd = (((((net_redemption_usd
    |> usd_add(UsdMicros { atoms : cooldown_funding })) ?
    |> usd_sub(chain_fees)) ?
    |> usd_sub(hedge_cost)) ?
    |> usd_sub(capital_delay_haircut)) ?
    |> usd_sub(final_hedge_close_cost)) ?

  Ok(DirectUnstakeProcess {
    state : Requested,
    requested_epoch : current_epoch,
    available_epoch : (current_epoch |> Checked.add(1)) ?,
    projection : DirectUnstakeProjection {
      protocol_redemption_lamports : protocol_redemption,
      withdrawal_fee_lamports : Lamports { atoms : withdrawal_fee },
      net_redemption_lamports : Lamports { atoms : net_redemption },
      protocol_redemption_usd_micros : protocol_redemption_usd,
      withdrawal_fee_usd_micros : withdrawal_fee_usd,
      cooldown_funding_usd_micros : UsdMicros { atoms : cooldown_funding },
      chain_fees_usd_micros : chain_fees,
      hedge_cost_usd_micros : hedge_cost,
      capital_delay_haircut_usd_micros : capital_delay_haircut,
      final_hedge_close_cost_usd_micros : final_hedge_close_cost,
      net_usd_micros : net_usd
    }
  })
end

pub fn advance_direct_unstake(
  process :: DirectUnstakeProcess,
  current_epoch :: Int,
  failed :: Bool
) -> DirectUnstakeProcess ! String do
  if current_epoch < process.requested_epoch do
    return Err("direct unstake epoch cannot move backward")
  end
  if failed do
    return Ok(process |> with_direct_unstake_state(Failed))
  end

  let next_state = case process.state do
    Requested -> Deactivating
    Deactivating -> WaitingForEpoch
    WaitingForEpoch -> if current_epoch >= process.available_epoch do Withdrawable else WaitingForEpoch end
    Withdrawable -> Withdrawable
    Withdrawn -> Withdrawn
    Failed -> Failed
  end
  Ok(process |> with_direct_unstake_state(next_state))
end

pub fn complete_direct_unstake(
  process :: DirectUnstakeProcess,
  failed :: Bool
) -> DirectUnstakeProcess ! String do
  if process.state != Withdrawable do
    return Err("direct unstake is not withdrawable")
  end
  Ok(process |> with_direct_unstake_state(
    if failed do Failed else Withdrawn end
  ))
end
