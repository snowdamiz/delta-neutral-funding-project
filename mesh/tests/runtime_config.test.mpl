from Packages.RuntimeConfig import RuntimeConfig, canonical_runtime_config, runtime_config_hash, validate_runtime_config

fn baseline() -> RuntimeConfig do
  RuntimeConfig {
    execution_mode : "paper",
    adapter_mode : "synthetic",
    emit_interval_ms : 10000,
    funding_interval_events : 12,
    funding_scan_interval_ms : 3600000,
    source_max_slot_drift : 5000,
    source_max_funding_age_ms : 7200000,
    source_max_borrow_age_ms : 7200000,
    target_notional_usd_micros : 500000000,
    paper_maximum_jitosol_atoms : 10000000000,
    paper_collateral_usd_micros : 500000000,
    paper_costs_usd_micros : 200000,
    paper_risk_haircut_usd_micros : 50000,
    paper_slippage_bps : 50,
    expected_hold_hours : 72,
    maximum_break_even_hours : 48,
    reverse_minimum_negative_funding_ppm : 10,
    reverse_maximum_borrow_utilization_ppm : 950000,
    jitosol_reward_haircut_ppm : 250000,
    max_source_age_ms : 5000,
    minimum_margin_ratio_ppm : 1500000,
    minimum_liquidation_distance_bps : 1000,
    rebalance_delta_bps : 50,
    execution_policy_profile : "shadow-v1",
    execution_intent_ttl_ms : 5000,
    maximum_execution_slippage_bps : 50,
    direct_unstake_scenario : "withdraw",
    direct_unstake_fee_ppm : 1000,
    direct_unstake_chain_fees_usd_micros : 20000,
    direct_unstake_hedge_cost_usd_micros : 0,
    direct_unstake_capital_delay_haircut_usd_micros : 1000000,
    direct_unstake_final_hedge_close_cost_usd_micros : 250000
  }
end

describe("runtime configuration identity") do
  test("fingerprints every strategy setting in a deterministic canonical form") do
    let config = baseline()
    case validate_runtime_config(config) do
      Ok(valid) -> assert(valid == config)
      Err(reason) -> assert(false)
    end
    assert(canonical_runtime_config(config) == "{\"adapterMode\":\"synthetic\",\"configSchemaVersion\":1,\"directUnstakeCapitalDelayHaircutUsdMicros\":\"1000000\",\"directUnstakeChainFeesUsdMicros\":\"20000\",\"directUnstakeFeePpm\":\"1000\",\"directUnstakeFinalHedgeCloseCostUsdMicros\":\"250000\",\"directUnstakeHedgeCostUsdMicros\":\"0\",\"directUnstakeScenario\":\"withdraw\",\"emitIntervalMs\":\"10000\",\"executionIntentTtlMs\":\"5000\",\"executionMode\":\"paper\",\"executionPolicyProfile\":\"shadow-v1\",\"expectedHoldHours\":\"72\",\"fundingIntervalEvents\":\"12\",\"fundingScanIntervalMs\":\"3600000\",\"jitosolRewardHaircutPpm\":\"250000\",\"maxSourceAgeMs\":\"5000\",\"maximumBreakEvenHours\":\"48\",\"maximumExecutionSlippageBps\":\"50\",\"minimumLiquidationDistanceBps\":\"1000\",\"minimumMarginRatioPpm\":\"1500000\",\"paperCollateralUsdMicros\":\"500000000\",\"paperCostsUsdMicros\":\"200000\",\"paperMaximumJitoSolAtoms\":\"10000000000\",\"paperRiskHaircutUsdMicros\":\"50000\",\"paperSlippageBps\":\"50\",\"rebalanceDeltaBps\":\"50\",\"reverseMaximumBorrowUtilizationPpm\":\"950000\",\"reverseMinimumNegativeFundingPpm\":\"10\",\"sourceMaxBorrowAgeMs\":\"7200000\",\"sourceMaxFundingAgeMs\":\"7200000\",\"sourceMaxSlotDrift\":\"5000\",\"targetNotionalUsdMicros\":\"500000000\"}")
    assert(runtime_config_hash(config) == "a2b4c29e2acbfb35264e1314cbdd467b3de70668adfa64df316ef163f1ff840e")
    assert(runtime_config_hash(%{config |
      paper_slippage_bps : 100
    }) != runtime_config_hash(config))
  end

  test("rejects unsafe policy values before startup") do
    case validate_runtime_config(%{baseline() |
      maximum_execution_slippage_bps : 10001
    }) do
      Ok(config) -> assert(false)
      Err(reason) -> assert(reason == "MAX_EXECUTION_SLIPPAGE_BPS must be between 0 and 10000")
    end
    case validate_runtime_config(%{baseline() |
      direct_unstake_scenario : "invented"
    }) do
      Ok(config) -> assert(false)
      Err(reason) -> assert(reason == "DIRECT_UNSTAKE_SCENARIO must be withdraw, miss, or fail")
    end
    case validate_runtime_config(%{baseline() |
      maximum_break_even_hours : 0
    }) do
      Ok(config) -> assert(false)
      Err(reason) -> assert(reason == "MAXIMUM_BREAK_EVEN_HOURS must be positive")
    end
    case validate_runtime_config(%{baseline() |
      reverse_maximum_borrow_utilization_ppm : 1000001
    }) do
      Ok(config) -> assert(false)
      Err(reason) -> assert(reason == "REVERSE_MAX_BORROW_UTILIZATION_PPM must be between 1 and 1000000")
    end
  end
end
