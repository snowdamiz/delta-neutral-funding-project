#!/bin/sh
set -eu

base_url=${1:-http://127.0.0.1:8080}
build=$(curl -fsS "$base_url/v1/build")
config=$(curl -fsS "$base_url/v1/config")
status=$(curl -fsS "$base_url/v1/status")
portfolios=$(curl -fsS "$base_url/v1/portfolios")

test "$(printf '%s' "$build" | jq -r .configHash)" = \
  "$(printf '%s' "$config" | jq -r .configHash)"
printf '%s' "$build" |
  jq -e '.schemaVersion == 42' >/dev/null
printf '%s' "$config" |
  jq -e '.configHash | test("^[0-9a-f]{64}$")' >/dev/null

printf '%s' "$status" |
  jq -e '.executionMode == "paper" and .signerReachable == false' >/dev/null
curl -fsS "$base_url/v1/adapter/status" |
  jq -e '.seen == true and .connected == true and .schemaVersion == 1' >/dev/null
curl -fsS "$base_url/v1/capabilities" |
  jq -e '
    .buildManifestId == "local-paper-build" and
    (.results | length) == 23 and
    any(.results[]; .id == "MESH-FIN-001" and .status == "implemented") and
    any(.results[]; .id == "MESH-ACTOR-001" and .status == "implemented") and
    any(.results[]; .id == "MESH-SIGNER-001" and .status == "deferred")
  ' >/dev/null
# The strategy catalog is the console's only enumeration of what exists, so the
# contract it renders from is asserted here: identity, declared benchmark, and a
# run state joined from the portfolios the strategy owns.
curl -fsS "$base_url/v1/strategies" |
  jq -e '
    .schemaVersion == 1 and
    (.strategies | length) == 9 and
    all(.strategies[];
      (.id | test("^[a-z0-9_]+$")) and
      (.displayName | length) > 0 and
      (.legs | type == "array" and length > 0) and
      (.mode == "paper") and
      (.controlScope == "global" or .controlScope == "strategy") and
      (.runState | test("^(active|idle|paused|unregistered)$")) and
      (.portfolioRunIds | type == "array")
    ) and
    any(.strategies[]; .id == "sol_control" and .benchmarkStrategyId == null) and
    any(.strategies[]; .id == "jitosol_carry" and .benchmarkStrategyId == "sol_control") and
    any(.strategies[]; .id == "cross_asset_funding" and .benchmarkStrategyId == "sol_control") and
    any(.strategies[]; .id == "negative_funding_reverse" and .benchmarkStrategyId == "sol_control") and
    any(.strategies[]; .id == "jitosol_nav_discount" and .family == "arbitrage" and .benchmarkStrategyId == "sol_control") and
    any(.strategies[]; .id == "cross_venue_funding" and .family == "arbitrage" and .benchmarkStrategyId == "sol_control") and
    any(.strategies[]; .id == "hyperliquid_wallet_flow" and .family == "signal" and .benchmarkStrategyId == "cross_asset_funding") and
    any(.strategies[]; .id == "hyperliquid_wallet_mirror" and .family == "signal" and .benchmarkStrategyId == "cross_asset_funding") and
    any(.strategies[]; .id == "hyperliquid_wallet_fade" and .family == "signal" and .benchmarkStrategyId == "cross_asset_funding") and
    ([.strategies[].portfolioRunIds[]] | sort) == (
      ["local-sol-control", "local-jitosol-carry", "local-cross-asset-funding", "local-negative-funding-reverse", "local-jitosol-nav-discount", "local-cross-venue-funding", "local-wallet-flow", "local-wallet-mirror", "local-wallet-fade", "local-sync-sol-control", "local-sync-jitosol-carry", "local-sync-cross-asset-funding", "local-sync-negative-funding-reverse", "local-sync-jitosol-nav-discount", "local-sync-cross-venue-funding", "local-sync-wallet-flow", "local-sync-wallet-mirror", "local-sync-wallet-fade"] | sort
    )
  ' >/dev/null
printf '%s' "$portfolios" |
  jq -e 'length == 18 and all(.[]; (.comparisonMode == "independent" or .comparisonMode == "synchronized") and .initialCapitalUsd.scale == 6)' >/dev/null
active=$(printf '%s' "$portfolios" |
  jq '[.[] | select(.state != "idle" and .state != "paused")] | length')
printf '%s' "$status" |
  jq -e \
    --argjson active "$active" \
    --arg target "$(printf '%s' "$config" | jq -r .targetNotionalUsdMicros)" \
    '(.activePortfolios | tonumber) == $active and
     (.liveNotional.atoms | tonumber) == $active * ($target | tonumber)' >/dev/null
curl -fsS "$base_url/v1/portfolios/local-sol-control" |
  jq -e '.id == "local-sol-control"' >/dev/null
curl -fsS "$base_url/v1/positions" |
  jq -e '
    length == 12 and
    all(.[];
      .spotQuantity.scale == 9 and
      if .variant == "cross_asset_funding" or .variant == "negative_funding_reverse" or .variant == "jitosol_nav_discount" then
        .marginSnapshot == null and (.asset | type == "string")
      elif .variant == "cross_venue_funding" then
        .marginSnapshot == null or (
          .marginSnapshot.collateralUsd.scale == 6 and
          .marginSnapshot.maintenanceRequirementUsd.scale == 6
        )
      else
        .marginSnapshot.collateralUsd.scale == 6 and
        .marginSnapshot.maintenanceRequirementUsd.scale == 6 and
        (
            (.marginSnapshot.collateralUsd.atoms | tonumber) * 1000000 /
            (.marginSnapshot.maintenanceRequirementUsd.atoms | tonumber) |
            floor | tostring
          ) == .marginSnapshot.marginRatioPpm
      end
    )
  ' >/dev/null
orders=$(curl -fsS "$base_url/v1/orders?limit=2&offset=0")
printf '%s' "$orders" |
  jq -e '.limit == 2 and .offset == 0 and (.items | length) <= 2 and all(.items[]; .intent.schemaVersion == 1 and .intent.intentId == .intentId and (.intent.snapshotIds | length) == 1 and (if .intent.leg == "PERP" then .intent.instrument == "SOL-PERP" elif .variant == "jitosol_carry" then .intent.instrument == "JUPITER:JITOSOL-USDC" else .intent.instrument == "JUPITER:SOL-USDC" end))' >/dev/null
if test "$(printf '%s' "$config" | jq -r .adapterMode)" = synthetic; then
  printf '%s' "$orders" | jq -e '(.items | length) > 0' >/dev/null
fi
curl -fsS "$base_url/v1/fills?limit=2&offset=0" |
  jq -e '.limit == 2 and (.items | length) <= 2' >/dev/null
curl -fsS "$base_url/v1/funding?limit=2&offset=0" |
  jq -e '.limit == 2 and all(.items[]; .amountUsd.scale == 6)' >/dev/null
curl -fsS "$base_url/v1/funding/leaderboard" |
  jq -e '.historyRequiredHours == "168" and .minimumSamples24h == "24" and all(.items[]; has("fundingRatePpmPerHour") and has("fundingEmaPpm") and has("gateDistancePpm"))' >/dev/null
curl -fsS "$base_url/v1/reverse-carry/leaderboard" |
  jq -e '.historyRequiredHours == "168" and .minimumSamples24h == "24" and .minimumNegativeFundingPpm == "10" and .maximumBorrowUtilizationPpm == "950000" and all(.items[]; has("funding24hAveragePpm") and has("borrowRatePpmPerHour") and has("gateDistancePpm"))' >/dev/null
curl -fsS "$base_url/v1/cross-venue/leaderboard" |
  jq -e '.historyRequiredHours == "168" and .minimumRealizedSamples24h == "24" and all(.items[]; has("realizedSpreadPpmPerHour") and has("shortMarginStatus") and has("longMarginStatus") and has("gateDistancePpm"))' >/dev/null
curl -fsS "$base_url/v1/wallets" |
  jq -e '
    (.config.version | test("^(0|[1-9][0-9]*)$")) and
    .config.maximumWallets == "50" and
    (.config.wallets | type == "array") and
    all(.config.wallets[]; test("^0x[0-9a-f]{40}$")) and
    .scores.minimumDecisions == "20" and
    (.scores.items | type == "array") and
    (.signals | type == "array") and
    (.positions | type == "array") and
    (.decisions | type == "array") and
    all(.assessment.modes[];
      .minimumDays == "60" and
      .minimumDecisions == "20" and
      (.verdict | test("^(pending|go|kill)$"))
    ) and
    (.assessment.benchmarks.holdingSol.ready | type == "boolean") and
    (.assessment.benchmarks.phase1.ready | type == "boolean")
  ' >/dev/null
curl -fsS "$base_url/v1/wallets/config" |
  jq -e '
    (.version | test("^(0|[1-9][0-9]*)$")) and
    .maximumWallets == "50" and
    (.wallets | type == "array") and
    all(.wallets[]; test("^0x[0-9a-f]{40}$"))
  ' >/dev/null
curl -fsS "$base_url/v1/pnl" |
  jq -e 'length == 18 and all(.[]; .scope == "recorded_attribution_v1" and .borrowInterestUsd.scale == 6)' >/dev/null
curl -fsS "$base_url/v1/pnl/comparison" |
  jq -e 'length == 2 and any(.[]; .mode == "independent") and any(.[]; .mode == "synchronized") and all(.[]; .jitosolIncrementalNetRecordedUsd.scale == 6)' >/dev/null
curl -fsS "$base_url/v1/jitosol" |
  jq -e '.directUnstakeCounterfactuals | type == "array"' >/dev/null
curl -fsS "$base_url/v1/risk-decisions?limit=4&offset=0" |
  jq -e '
    .limit == 4 and
    (.items | length) > 0 and
    all(.items[];
      (
        (
          (.healthSnapshot.collateralUsdMicros | tonumber) * 1000000 /
          (.healthSnapshot.maintenanceRequirementUsdMicros | tonumber) |
          floor | tostring
        ) == .healthSnapshot.marginRatioPpm
      )
    )
  ' >/dev/null
printf '%s' "$config" |
  jq -e '.executionMode == "paper" and (.adapterMode == "synthetic" or .adapterMode == "authoritative") and .liveEnabled == false and .databaseSchemaVersion == 39 and .fundingScanIntervalMs == 3600000 and .sourceMaxBorrowAgeMs == 7200000 and .targetNotionalUsdMicros == "500000000" and .paperMaximumJitoSolAtoms == "10000000000" and .paperCollateralUsdMicros == "500000000" and .paperCostsUsdMicros == "200000" and .paperRiskHaircutUsdMicros == "50000" and .paperSlippageBps == 50 and .expectedHoldHours == 72 and .maximumBreakEvenHours == 48 and .reverseMinimumNegativeFundingPpm == 10 and .reverseMaximumBorrowUtilizationPpm == 950000 and .jitosolRewardHaircutPpm == 250000 and .maxSourceAgeMs == 60000 and .minimumMarginRatioPpm == 1500000 and .minimumLiquidationDistanceBps == 1000 and .executionPolicyProfile == "shadow-v1" and .executionIntentTtlMs == 5000 and .maximumExecutionSlippageBps == 50' >/dev/null

test "$(curl -sS -o /dev/null -w '%{http_code}' "$base_url/v1/orders?limit=101")" = "400"
printf 'read API checks passed\n'
