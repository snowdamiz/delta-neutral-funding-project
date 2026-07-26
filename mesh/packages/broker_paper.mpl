from Packages.Finance import PriceMicros, QuantityAtoms, RatePpm, UsdMicros

pub type OrderSide do
  Buy
  Sell
end deriving(Eq, Display, Json)

pub type FillStatus do
  Filled
  Partial
  Rejected
end deriving(Eq, Display, Json)

pub type FailureOutcome do
  Continue
  Reject
  Unknown
end deriving(Eq, Display, Json)

pub struct PaperOrder do
  side :: OrderSide
  quantity :: QuantityAtoms
  quantity_scale :: Int
  quoted_price :: PriceMicros
  fill_rate :: RatePpm
  slippage_rate :: RatePpm
  fee_rate :: RatePpm
end

pub struct PaperFill do
  status :: FillStatus
  filled_quantity :: QuantityAtoms
  average_price :: PriceMicros
  gross_usd :: UsdMicros
  fee_usd :: UsdMicros
end deriving(Json)

pub struct SampledFailure do
  random_state :: Int
  outcome :: FailureOutcome
  draw_ppm :: Int
end deriving(Json)

fn valid_rate(rate :: RatePpm) -> Bool do
  rate.atoms >= 0 && rate.atoms <= 1000000
end

fn validate_order(order :: PaperOrder) -> PaperOrder ! String do
  if order.quantity.atoms <= 0 do
    return Err("paper quantity must be positive")
  end
  if order.quantity_scale <= 0 do
    return Err("paper quantity scale must be positive")
  end
  if order.quoted_price.atoms <= 0 do
    return Err("paper price must be positive")
  end
  if valid_rate(order.fill_rate) == false do
    return Err("paper fill rate must be between zero and one million ppm")
  end
  if valid_rate(order.slippage_rate) == false do
    return Err("paper slippage rate must be between zero and one million ppm")
  end
  if valid_rate(order.fee_rate) == false do
    return Err("paper fee rate must be between zero and one million ppm")
  end
  Ok(order)
end

fn adverse_price(order :: PaperOrder) -> Int ! String do
  case order.side do
    Buy -> do
      let multiplier = Checked.add(1000000, order.slippage_rate.atoms) ?
      order.quoted_price.atoms |> Checked.mul_div(multiplier, 1000000, :ceil)
    end
    Sell -> do
      let multiplier = Checked.sub(1000000, order.slippage_rate.atoms) ?
      order.quoted_price.atoms |> Checked.mul_div(multiplier, 1000000, :floor)
    end
  end
end

fn fill_status(fill_rate :: RatePpm) -> FillStatus do
  if fill_rate.atoms == 0 do
    Rejected
  else
    if fill_rate.atoms == 1000000 do
      Filled
    else
      Partial
    end
  end
end

pub fn simulate_fill(order :: PaperOrder) -> PaperFill ! String do
  let validated = validate_order(order) ?
  let filled_atoms = (validated.quantity.atoms |> Checked.mul_div(validated.fill_rate.atoms, 1000000, :floor)) ?
  let price_atoms = adverse_price(validated) ?
  let gross_atoms = (filled_atoms |> Checked.mul_div(price_atoms, validated.quantity_scale, :ceil)) ?
  let fee_atoms = (gross_atoms |> Checked.mul_div(validated.fee_rate.atoms, 1000000, :ceil)) ?
  Ok(PaperFill {
    status : fill_status(validated.fill_rate),
    filled_quantity : QuantityAtoms { atoms : filled_atoms },
    average_price : PriceMicros { atoms : price_atoms },
    gross_usd : UsdMicros { atoms : gross_atoms },
    fee_usd : UsdMicros { atoms : fee_atoms }
  })
end

pub fn sample_failure(random_state :: Int, reject_rate :: RatePpm, unknown_rate :: RatePpm) -> SampledFailure ! String do
  if valid_rate(reject_rate) == false || valid_rate(unknown_rate) == false do
    return Err("paper failure rates must be between zero and one million ppm")
  end
  let unknown_limit = (reject_rate.atoms |> Checked.add(unknown_rate.atoms)) ?
  if unknown_limit > 1000000 do
    return Err("paper failure rates exceed one million ppm")
  end

  let sampled = Random.next_unit_ppm(random_state)
  let draw = Tuple.second(sampled)
  let outcome = if draw < reject_rate.atoms do
    Reject
  else
    if draw < unknown_limit do Unknown else Continue end
  end
  Ok(SampledFailure {
    random_state : Tuple.first(sampled),
    outcome : outcome,
    draw_ppm : draw
  })
end
