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
