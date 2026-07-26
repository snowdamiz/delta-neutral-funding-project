pub struct RuntimeConfig do
  execution_mode :: String
  adapter_mode :: String
  emit_interval_ms :: Int
  funding_interval_events :: Int
  source_max_slot_drift :: Int
  source_max_funding_age_ms :: Int
  target_notional_usd_micros :: Int
  paper_maximum_jitosol_atoms :: Int
  paper_collateral_usd_micros :: Int
  paper_costs_usd_micros :: Int
  paper_risk_haircut_usd_micros :: Int
  paper_slippage_bps :: Int
  max_source_age_ms :: Int
  minimum_margin_ratio_ppm :: Int
  minimum_liquidation_distance_bps :: Int
  rebalance_delta_bps :: Int
  execution_policy_profile :: String
  execution_intent_ttl_ms :: Int
  maximum_execution_slippage_bps :: Int
  direct_unstake_scenario :: String
  direct_unstake_fee_ppm :: Int
  direct_unstake_chain_fees_usd_micros :: Int
  direct_unstake_hedge_cost_usd_micros :: Int
  direct_unstake_capital_delay_haircut_usd_micros :: Int
  direct_unstake_final_hedge_close_cost_usd_micros :: Int
end deriving(Eq)

fn unsigned_env(name :: String, fallback :: Int) -> Int ! String do
  let raw = Env.get(name, fallback.to_string())
  if Regex.is_match(~r/^(0|[1-9][0-9]*)$/, raw) == false do
    return Err("${name} must be a canonical non-negative integer")
  end
  case String.to_int(raw) do
    Some(value) -> Ok(value)
    None -> Err("${name} is outside the supported integer range")
  end
end

pub fn load_runtime_config() -> RuntimeConfig ! String do
  RuntimeConfig {
    execution_mode : Env.get("EXECUTION_MODE", ""),
    adapter_mode : Env.get("ADAPTER_MODE", "synthetic"),
    emit_interval_ms : ("EMIT_INTERVAL_MS"
      |> unsigned_env(10000)) ?,
    funding_interval_events : ("FUNDING_INTERVAL_EVENTS"
      |> unsigned_env(12)) ?,
    source_max_slot_drift : ("SOURCE_MAX_SLOT_DRIFT"
      |> unsigned_env(5000)) ?,
    source_max_funding_age_ms : ("SOURCE_MAX_FUNDING_AGE_MS"
      |> unsigned_env(7200000)) ?,
    target_notional_usd_micros : ("PAPER_NOTIONAL_USD_MICROS"
      |> unsigned_env(500000000)) ?,
    paper_maximum_jitosol_atoms : ("PAPER_MAX_JITOSOL_ATOMS"
      |> unsigned_env(10000000000)) ?,
    paper_collateral_usd_micros : ("PAPER_COLLATERAL_USD_MICROS"
      |> unsigned_env(500000000)) ?,
    paper_costs_usd_micros : ("PAPER_COSTS_USD_MICROS"
      |> unsigned_env(200000)) ?,
    paper_risk_haircut_usd_micros : ("PAPER_RISK_HAIRCUT_USD_MICROS"
      |> unsigned_env(50000)) ?,
    paper_slippage_bps : ("PAPER_SLIPPAGE_BPS"
      |> unsigned_env(50)) ?,
    max_source_age_ms : ("MAX_SOURCE_AGE_MS"
      |> unsigned_env(5000)) ?,
    minimum_margin_ratio_ppm : ("MIN_MARGIN_RATIO_PPM"
      |> unsigned_env(1500000)) ?,
    minimum_liquidation_distance_bps : ("MIN_LIQUIDATION_DISTANCE_BPS"
      |> unsigned_env(1000)) ?,
    rebalance_delta_bps : ("REBALANCE_DELTA_BPS"
      |> unsigned_env(50)) ?,
    execution_policy_profile : Env.get(
      "EXECUTION_POLICY_PROFILE",
      "shadow-v1"
    ),
    execution_intent_ttl_ms : ("EXECUTION_INTENT_TTL_MS"
      |> unsigned_env(5000)) ?,
    maximum_execution_slippage_bps : ("MAX_EXECUTION_SLIPPAGE_BPS"
      |> unsigned_env(50)) ?,
    direct_unstake_scenario : Env.get(
      "DIRECT_UNSTAKE_SCENARIO",
      "withdraw"
    ),
    direct_unstake_fee_ppm : ("DIRECT_UNSTAKE_FEE_PPM"
      |> unsigned_env(1000)) ?,
    direct_unstake_chain_fees_usd_micros : (
      "DIRECT_UNSTAKE_CHAIN_FEES_USD_MICROS"
      |> unsigned_env(20000)
    ) ?,
    direct_unstake_hedge_cost_usd_micros : (
      "DIRECT_UNSTAKE_HEDGE_COST_USD_MICROS"
      |> unsigned_env(0)
    ) ?,
    direct_unstake_capital_delay_haircut_usd_micros : (
      "DIRECT_UNSTAKE_CAPITAL_DELAY_HAIRCUT_USD_MICROS"
      |> unsigned_env(1000000)
    ) ?,
    direct_unstake_final_hedge_close_cost_usd_micros : (
      "DIRECT_UNSTAKE_FINAL_HEDGE_CLOSE_COST_USD_MICROS"
      |> unsigned_env(250000)
    ) ?
  }
    |> validate_runtime_config
end

pub fn validate_runtime_config(
  config :: RuntimeConfig
) -> RuntimeConfig ! String do
  if config.execution_mode != "paper" do
    return Err("EXECUTION_MODE must be paper")
  end
  if (["synthetic", "authoritative"]
    |> List.contains(config.adapter_mode)) == false do
    return Err("ADAPTER_MODE must be synthetic or authoritative")
  end
  if config.emit_interval_ms <= 0 do
    return Err("EMIT_INTERVAL_MS must be positive")
  end
  if config.funding_interval_events <= 0 do
    return Err("FUNDING_INTERVAL_EVENTS must be positive")
  end
  if config.source_max_funding_age_ms <= 0 do
    return Err("SOURCE_MAX_FUNDING_AGE_MS must be positive")
  end
  if config.target_notional_usd_micros <= 0 do
    return Err("PAPER_NOTIONAL_USD_MICROS must be positive")
  end
  if config.paper_maximum_jitosol_atoms <= 0 do
    return Err("PAPER_MAX_JITOSOL_ATOMS must be positive")
  end
  if config.paper_collateral_usd_micros <= 0 do
    return Err("PAPER_COLLATERAL_USD_MICROS must be positive")
  end
  if config.paper_slippage_bps > 10000 do
    return Err("PAPER_SLIPPAGE_BPS must be between 0 and 10000")
  end
  if config.max_source_age_ms <= 0 do
    return Err("MAX_SOURCE_AGE_MS must be positive")
  end
  if config.minimum_margin_ratio_ppm <= 0 do
    return Err("MIN_MARGIN_RATIO_PPM must be positive")
  end
  if config.rebalance_delta_bps <= 0 || config.rebalance_delta_bps > 10000 do
    return Err("REBALANCE_DELTA_BPS must be between 1 and 10000")
  end
  if Regex.is_match(
    ~r/^[a-z0-9][a-z0-9._-]{0,63}$/,
    config.execution_policy_profile
  ) == false do
    return Err("EXECUTION_POLICY_PROFILE is invalid")
  end
  if config.execution_intent_ttl_ms <= 0 do
    return Err("EXECUTION_INTENT_TTL_MS must be positive")
  end
  if config.maximum_execution_slippage_bps > 10000 do
    return Err("MAX_EXECUTION_SLIPPAGE_BPS must be between 0 and 10000")
  end
  if (["withdraw", "miss", "fail"]
    |> List.contains(config.direct_unstake_scenario)) == false do
    return Err("DIRECT_UNSTAKE_SCENARIO must be withdraw, miss, or fail")
  end
  if config.direct_unstake_fee_ppm > 1000000 do
    return Err("DIRECT_UNSTAKE_FEE_PPM must be between 0 and 1000000")
  end
  Ok(config)
end

pub fn canonical_runtime_config(config :: RuntimeConfig) -> String do
  "{\"adapterMode\":\"${config.adapter_mode}\",\"configSchemaVersion\":1,\"directUnstakeCapitalDelayHaircutUsdMicros\":\"${config.direct_unstake_capital_delay_haircut_usd_micros}\",\"directUnstakeChainFeesUsdMicros\":\"${config.direct_unstake_chain_fees_usd_micros}\",\"directUnstakeFeePpm\":\"${config.direct_unstake_fee_ppm}\",\"directUnstakeFinalHedgeCloseCostUsdMicros\":\"${config.direct_unstake_final_hedge_close_cost_usd_micros}\",\"directUnstakeHedgeCostUsdMicros\":\"${config.direct_unstake_hedge_cost_usd_micros}\",\"directUnstakeScenario\":\"${config.direct_unstake_scenario}\",\"emitIntervalMs\":\"${config.emit_interval_ms}\",\"executionIntentTtlMs\":\"${config.execution_intent_ttl_ms}\",\"executionMode\":\"${config.execution_mode}\",\"executionPolicyProfile\":\"${config.execution_policy_profile}\",\"fundingIntervalEvents\":\"${config.funding_interval_events}\",\"maxSourceAgeMs\":\"${config.max_source_age_ms}\",\"maximumExecutionSlippageBps\":\"${config.maximum_execution_slippage_bps}\",\"minimumLiquidationDistanceBps\":\"${config.minimum_liquidation_distance_bps}\",\"minimumMarginRatioPpm\":\"${config.minimum_margin_ratio_ppm}\",\"paperCollateralUsdMicros\":\"${config.paper_collateral_usd_micros}\",\"paperCostsUsdMicros\":\"${config.paper_costs_usd_micros}\",\"paperMaximumJitoSolAtoms\":\"${config.paper_maximum_jitosol_atoms}\",\"paperRiskHaircutUsdMicros\":\"${config.paper_risk_haircut_usd_micros}\",\"paperSlippageBps\":\"${config.paper_slippage_bps}\",\"rebalanceDeltaBps\":\"${config.rebalance_delta_bps}\",\"sourceMaxFundingAgeMs\":\"${config.source_max_funding_age_ms}\",\"sourceMaxSlotDrift\":\"${config.source_max_slot_drift}\",\"targetNotionalUsdMicros\":\"${config.target_notional_usd_micros}\"}"
end

pub fn runtime_config_hash(config :: RuntimeConfig) -> String do
  config
    |> canonical_runtime_config
    |> Crypto.sha256
end
