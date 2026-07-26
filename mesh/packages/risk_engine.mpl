from Packages.Finance import Lamports, UsdMicros

pub struct RiskInput do
  observed_at_ms :: Int
  now_ms :: Int
  max_age_ms :: Int
  paused :: Bool
  oracle_valid :: Bool
  exit_depth :: Lamports
  hedge :: Lamports
  net_carry :: UsdMicros
end

pub struct RiskDecision do
  approved :: Bool
  code :: String
end deriving(Eq, Json)

fn reject(code :: String) -> RiskDecision do
  RiskDecision { approved : false, code : code }
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
  if input.exit_depth.atoms < input.hedge.atoms do
    return reject("insufficient_exit_depth")
  end
  if input.net_carry.atoms <= 0 do
    return reject("non_positive_net_carry")
  end
  input.observed_at_ms
    |> source_health(input.now_ms, input.max_age_ms)
end
