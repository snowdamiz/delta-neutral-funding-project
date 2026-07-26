pub struct ExecutionIntent do
  intent_id :: String
  strategy_run_id :: String
  state_version :: Int
  variant :: String
  operation :: String
  leg :: String
  instrument :: String
  side :: String
  max_quantity_atoms :: Int
  limit_price_atoms :: Int
  max_slippage_bps :: Int
  reduce_only :: Bool
  expires_at_ms :: Int
  policy_profile :: String
  snapshot_ids :: List<String>
  config_hash :: String
end

fn valid_identity(value :: String) -> Bool do
  String.length(String.trim(value)) > 0
end

fn valid_snapshots(ids :: List<String>) -> Bool do
  List.length(ids) > 0 && List.length(for id in ids when valid_identity(id) == false do id end) == 0
end

fn valid_variant(value :: String) -> Bool do
  case value do
    "sol_control" -> true
    "jitosol_carry" -> true
    _ -> false
  end
end

fn valid_operation(value :: String) -> Bool do
  case value do
    "OPEN" -> true
    "REBALANCE" -> true
    "CLOSE" -> true
    "EMERGENCY_FLATTEN" -> true
    _ -> false
  end
end

fn valid_leg(value :: String) -> Bool do
  case value do
    "SPOT" -> true
    "PERP" -> true
    _ -> false
  end
end

fn valid_side(value :: String) -> Bool do
  case value do
    "BUY" -> true
    "SELL" -> true
    _ -> false
  end
end

fn validate(intent :: ExecutionIntent) -> ExecutionIntent ! String do
  if valid_identity(intent.intent_id) == false || valid_identity(intent.strategy_run_id) == false do
    return Err("execution intent identity is required")
  end
  if valid_variant(intent.variant) == false do
    return Err("invalid execution intent variant")
  end
  if valid_operation(intent.operation) == false do
    return Err("invalid execution intent operation")
  end
  if valid_leg(intent.leg) == false || valid_side(intent.side) == false do
    return Err("invalid execution intent leg or side")
  end
  if intent.state_version < 0 || intent.max_quantity_atoms <= 0 || intent.limit_price_atoms <= 0 do
    return Err("invalid execution intent quantity or version")
  end
  if intent.max_slippage_bps < 0 || intent.max_slippage_bps > 10000 || intent.expires_at_ms <= 0 do
    return Err("invalid execution intent slippage or expiry")
  end
  if valid_identity(intent.instrument) == false || valid_identity(intent.policy_profile) == false do
    return Err("execution intent instrument and policy are required")
  end
  if valid_snapshots(intent.snapshot_ids) == false do
    return Err("execution intent snapshots are required")
  end
  if Regex.is_match(~r/^[0-9a-f]{64}$/, intent.config_hash) == false do
    return Err("execution intent config hash must be lowercase sha256")
  end
  Ok(intent)
end

pub fn canonical_execution_intent(value :: ExecutionIntent) -> String ! String do
  let intent = validate(value) ?
  Ok(json {
    schemaVersion : 1,
    intentId : intent.intent_id,
    strategyRunId : intent.strategy_run_id,
    stateVersion : "${intent.state_version}",
    variant : intent.variant,
    operation : intent.operation,
    leg : intent.leg,
    instrument : intent.instrument,
    side : intent.side,
    maxQuantityAtoms : "${intent.max_quantity_atoms}",
    limitPriceAtoms : "${intent.limit_price_atoms}",
    maxSlippageBps : "${intent.max_slippage_bps}",
    reduceOnly : intent.reduce_only,
    expiresAtMs : "${intent.expires_at_ms}",
    policyProfile : intent.policy_profile,
    snapshotIds : intent.snapshot_ids,
    configHash : intent.config_hash
  })
end

pub fn execution_intent_hash(intent :: ExecutionIntent) -> String ! String do
  Ok((intent
    |> canonical_execution_intent) ?
    |> Crypto.sha256)
end
