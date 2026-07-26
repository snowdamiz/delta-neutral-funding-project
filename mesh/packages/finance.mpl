pub struct Lamports do
  atoms :: Int
end deriving(Eq, Json)

pub struct TokenAtoms do
  atoms :: Int
end deriving(Eq, Json)

pub struct UsdMicros do
  atoms :: Int
end deriving(Eq, Json)

pub struct RatePpm do
  atoms :: Int
end deriving(Eq, Json)

pub struct QuantityAtoms do
  atoms :: Int
end deriving(Eq, Json)

pub struct PriceMicros do
  atoms :: Int
end deriving(Eq, Json)

pub struct PositionDelta do
  spot_equivalent_lamports :: Lamports
  delta_lamports :: Lamports
  delta_bps :: Int
end deriving(Eq, Json)

pub fn lamports_ratio(total :: Lamports, supply :: TokenAtoms, rounding :: Atom) -> Lamports ! String do
  case Checked.mul_div(total.atoms, 1000000000, supply.atoms, rounding) do
    Ok(atoms) -> Ok(Lamports { atoms : atoms })
    Err(error) -> Err(error)
  end
end

pub fn token_value_lamports(quantity :: TokenAtoms, rate :: Lamports, rounding :: Atom) -> Lamports ! String do
  case Checked.mul_div(quantity.atoms, rate.atoms, 1000000000, rounding) do
    Ok(atoms) -> Ok(Lamports { atoms : atoms })
    Err(error) -> Err(error)
  end
end

pub fn position_delta(
  spot_quantity :: TokenAtoms,
  market_rate :: Lamports,
  perp_short :: Lamports
) -> PositionDelta ! String do
  let spot_equivalent = (spot_quantity
    |> token_value_lamports(market_rate, :floor)) ?
  let delta = (spot_equivalent.atoms
    |> Checked.sub(perp_short.atoms)) ?
  let delta_bps = if spot_equivalent.atoms == 0 do
    0
  else
    ((delta
      |> Checked.abs) ?
      |> Checked.mul_div(10000, spot_equivalent.atoms, :ceil)) ?
  end
  Ok(PositionDelta {
    spot_equivalent_lamports : spot_equivalent,
    delta_lamports : Lamports { atoms : delta },
    delta_bps : delta_bps
  })
end

pub fn apply_rate(amount :: UsdMicros, rate :: RatePpm, rounding :: Atom) -> UsdMicros ! String do
  case Checked.mul_div(amount.atoms, rate.atoms, 1000000, rounding) do
    Ok(atoms) -> Ok(UsdMicros { atoms : atoms })
    Err(error) -> Err(error)
  end
end

pub fn lamports_to_usd(amount :: Lamports, price :: UsdMicros, rounding :: Atom) -> UsdMicros ! String do
  case Checked.mul_div(amount.atoms, price.atoms, 1000000000, rounding) do
    Ok(atoms) -> Ok(UsdMicros { atoms : atoms })
    Err(error) -> Err(error)
  end
end

pub fn usd_add(left :: UsdMicros, right :: UsdMicros) -> UsdMicros ! String do
  case Checked.add(left.atoms, right.atoms) do
    Ok(atoms) -> Ok(UsdMicros { atoms : atoms })
    Err(error) -> Err(error)
  end
end

pub fn usd_sub(left :: UsdMicros, right :: UsdMicros) -> UsdMicros ! String do
  case Checked.sub(left.atoms, right.atoms) do
    Ok(atoms) -> Ok(UsdMicros { atoms : atoms })
    Err(error) -> Err(error)
  end
end
