from Packages.Finance import Lamports, UsdMicros

pub struct MarginInput do
  collateral_usd_micros :: UsdMicros
  maintenance_requirement_usd_micros :: UsdMicros
  minimum_margin_ratio_ppm :: Int
  liquidation_distance_bps :: Int
  minimum_liquidation_distance_bps :: Int
end

pub struct RiskInput do
  observed_at_ms :: Int
  now_ms :: Int
  max_age_ms :: Int
  paused :: Bool
  oracle_valid :: Bool
  exit_depth :: Lamports
  hedge :: Lamports
  net_carry :: UsdMicros
  margin :: MarginInput
end

pub struct RiskDecision do
  approved :: Bool
  code :: String
end deriving(Eq, Json)

fn reject(code :: String) -> RiskDecision do
  RiskDecision { approved : false, code : code }
end

pub fn margin_health(input :: MarginInput) -> RiskDecision do
  if input.maintenance_requirement_usd_micros.atoms <= 0 || input.minimum_margin_ratio_ppm <= 0 || input.liquidation_distance_bps < 0 || input.minimum_liquidation_distance_bps < 0 do
    return reject("margin_input_invalid")
  end
  case input.collateral_usd_micros.atoms
    |> Checked.mul_div(1000000, input.maintenance_requirement_usd_micros.atoms, :floor) do
    Ok(ratio) -> if ratio < input.minimum_margin_ratio_ppm do
      reject("margin_ratio_below_minimum")
    else
      if input.liquidation_distance_bps < input.minimum_liquidation_distance_bps do
        reject("liquidation_distance_below_minimum")
      else
        RiskDecision { approved : true, code : "approved" }
      end
    end
    Err(error) -> reject("margin_input_invalid")
  end
end

pub fn source_health(
  observed_at_ms :: Int,
  now_ms :: Int,
  max_age_ms :: Int
) -> RiskDecision do
  if max_age_ms < 0 do
    return reject("source_time_invalid")
  end
  if now_ms < observed_at_ms do
    return reject("source_time_in_future")
  end
  case now_ms |> Checked.sub(observed_at_ms) do
    Ok(age_ms) -> if age_ms > max_age_ms do
      reject("source_stale")
    else
      RiskDecision { approved : true, code : "approved" }
    end
    Err(error) -> reject("source_time_invalid")
  end
end

pub fn approve_entry(input :: RiskInput) -> RiskDecision do
  if input.paused do
    return reject("entries_paused")
  end
  if input.oracle_valid == false do
    return reject("oracle_invalid")
  end
  let margin = input.margin |> margin_health
  if margin.approved == false do
    return margin
  end
  if input.exit_depth.atoms < input.hedge.atoms do
    return reject("insufficient_exit_depth")
  end
  if input.net_carry.atoms <= 0 do
    return reject("non_positive_net_carry")
  end
  input.observed_at_ms
    |> source_health(input.now_ms, input.max_age_ms)
end
