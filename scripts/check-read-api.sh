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
  jq -e '.schemaVersion == 54' >/dev/null
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
    (.schemaVersion == 2) and
    (.strategies | length) == 4 and
    all(.strategies[];
      (.id | test("^[a-z0-9_]+$")) and
      (.displayName | length) > 0 and
      (.legs | type == "array" and length > 0) and
      (.controlScope == "strategy") and
      (.enabled | type == "boolean") and
      (.benchmarkStrategyId == null) and
      (.runState | test("^(active|idle|paused|unregistered)$")) and
      (.portfolioRunIds | type == "array")
    ) and
    (.strategies[0].id == "solana_wallet_flow_quant") and
    (.strategies[0].mode | test("^(paper|live)$")) and
    any(.strategies[]; .id == "cross_asset_funding" and .family == "carry" and .mode == "paper") and
    any(.strategies[]; .id == "negative_funding_reverse" and .family == "carry" and .mode == "paper") and
    any(.strategies[]; .id == "jitosol_nav_discount" and .family == "arbitrage" and .mode == "paper") and
    ([.strategies[].portfolioRunIds[]] | sort) == (
      ["local-cross-asset-funding", "local-negative-funding-reverse", "local-jitosol-nav-discount"] | sort
    )
  ' >/dev/null
printf '%s' "$portfolios" |
  jq -e 'length == 3 and all(.[]; .comparisonMode == "independent" and .initialCapitalUsd.scale == 6)' >/dev/null
active=$(printf '%s' "$portfolios" |
  jq '[.[] | select(.state != "idle" and .state != "paused")] | length')
printf '%s' "$status" |
  jq -e \
    --argjson active "$active" \
    --arg target "$(printf '%s' "$config" | jq -r .targetNotionalUsdMicros)" \
    '(.activePortfolios | tonumber) == $active and
     (.liveNotional.atoms | tonumber) == $active * ($target | tonumber)' >/dev/null
curl -fsS "$base_url/v1/portfolios/local-jitosol-nav-discount" |
  jq -e '.id == "local-jitosol-nav-discount"' >/dev/null
curl -fsS "$base_url/v1/positions" |
  jq -e '
    length == 3 and
    all(.[];
      .spotQuantity.scale == 9 and
      .marginSnapshot == null and
      (.asset | type == "string") and
      (.variant | test("^(cross_asset_funding|negative_funding_reverse|jitosol_nav_discount)$"))
    )
  ' >/dev/null
curl -fsS "$base_url/v1/orders?limit=2&offset=0" |
  jq -e '.limit == 2 and .offset == 0 and (.items | length) <= 2' >/dev/null
curl -fsS "$base_url/v1/fills?limit=2&offset=0" |
  jq -e '.limit == 2 and (.items | length) <= 2' >/dev/null
curl -fsS "$base_url/v1/funding?limit=2&offset=0" |
  jq -e '.limit == 2 and all(.items[]; .amountUsd.scale == 6)' >/dev/null
curl -fsS "$base_url/v1/funding/leaderboard" |
  jq -e '.historyRequiredHours == "168" and .minimumSamples24h == "24" and all(.items[]; has("fundingRatePpmPerHour") and has("fundingEmaPpm") and has("gateDistancePpm"))' >/dev/null
curl -fsS "$base_url/v1/reverse-carry/leaderboard" |
  jq -e '.historyRequiredHours == "168" and .minimumSamples24h == "24" and .minimumNegativeFundingPpm == "10" and .maximumBorrowUtilizationPpm == "950000" and all(.items[]; has("funding24hAveragePpm") and has("borrowRatePpmPerHour") and has("gateDistancePpm"))' >/dev/null
curl -fsS "$base_url/v1/solana-wallet-flow/config" |
  jq -e '
    (.version | test("^(0|[1-9][0-9]*)$")) and
    .maximumWallets == "100" and
    (.wallets | type == "array") and
    all(.wallets[]; test("^[1-9A-HJ-NP-Za-km-z]{32,44}$"))
  ' >/dev/null
curl -fsS "$base_url/v1/pnl" |
  jq -e 'length == 3 and all(.[]; .scope == "recorded_attribution_v1" and .borrowInterestUsd.scale == 6)' >/dev/null
curl -fsS "$base_url/v1/jitosol" |
  jq -e '.directUnstakeCounterfactuals | type == "array"' >/dev/null
curl -fsS "$base_url/v1/solana-wallet-flow" |
  jq -e '
    (.cursors | type == "array") and
    (.openMints | type == "array") and
    (.positions | type == "array") and
    (.actions | type == "array") and
    (.discovery | type == "array") and
    (.paperAccount.initialCapitalUsdMicros | test("^[1-9][0-9]*$")) and
    (.strategyConfig.values.positionUsdMicros == "100000000") and
    (.brokerConfig.values.maxOpenPositions == "3") and
    (.brokerConfig.values.takeProfitMultipleBps == "20000") and
    (.live.mode | test("^(paper|live)$")) and
    (.live.config.values.perTradeCapUsdMicros == "250000000") and
    (.live.intents | type == "array") and
    (.live.positions | type == "array")
  ' >/dev/null
curl -fsS "$base_url/v1/risk-decisions?limit=4&offset=0" |
  jq -e '
    .limit == 4 and
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
  jq -e '.executionMode == "paper" and (.adapterMode == "synthetic" or .adapterMode == "authoritative") and .liveEnabled == false and .databaseSchemaVersion == 54 and .fundingScanIntervalMs == 3600000 and .sourceMaxBorrowAgeMs == 7200000 and .targetNotionalUsdMicros == "500000000" and .paperMaximumJitoSolAtoms == "10000000000" and .paperCollateralUsdMicros == "500000000" and .paperCostsUsdMicros == "200000" and .paperRiskHaircutUsdMicros == "50000" and .paperSlippageBps == 50 and .expectedHoldHours == 72 and .maximumBreakEvenHours == 48 and .reverseMinimumNegativeFundingPpm == 10 and .reverseMaximumBorrowUtilizationPpm == 950000 and .jitosolRewardHaircutPpm == 250000 and .maxSourceAgeMs == 60000 and .minimumMarginRatioPpm == 1500000 and .minimumLiquidationDistanceBps == 1000 and .executionPolicyProfile == "shadow-v1" and .executionIntentTtlMs == 5000 and .maximumExecutionSlippageBps == 50' >/dev/null

test "$(curl -sS -o /dev/null -w '%{http_code}' "$base_url/v1/orders?limit=101")" = "400"
printf 'read API checks passed\n'
