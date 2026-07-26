from Packages.Finance import Lamports, RatePpm, UsdMicros, apply_rate, lamports_to_usd

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
