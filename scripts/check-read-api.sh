#!/bin/sh
set -eu

base_url=${1:-http://127.0.0.1:8080}
build=$(curl -fsS "$base_url/v1/build")
config=$(curl -fsS "$base_url/v1/config")

test "$(printf '%s' "$build" | jq -r .configHash)" = \
  "$(printf '%s' "$config" | jq -r .configHash)"
printf '%s' "$config" |
  jq -e '.configHash | test("^[0-9a-f]{64}$")' >/dev/null

curl -fsS "$base_url/v1/status" |
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
curl -fsS "$base_url/v1/portfolios" |
  jq -e 'length == 4 and all(.[]; (.comparisonMode == "independent" or .comparisonMode == "synchronized") and .initialCapitalUsd.scale == 6)' >/dev/null
curl -fsS "$base_url/v1/portfolios/local-sol-control" |
  jq -e '.id == "local-sol-control"' >/dev/null
curl -fsS "$base_url/v1/positions" |
  jq -e '
    length == 4 and
    all(.[];
      .spotQuantity.scale == 9 and
      .marginSnapshot.collateralUsd.scale == 6 and
      .marginSnapshot.maintenanceRequirementUsd.scale == 6 and
      (
        (
          (.marginSnapshot.collateralUsd.atoms | tonumber) * 1000000 /
          (.marginSnapshot.maintenanceRequirementUsd.atoms | tonumber) |
          floor | tostring
        ) == .marginSnapshot.marginRatioPpm
      )
    )
  ' >/dev/null
curl -fsS "$base_url/v1/orders?limit=2&offset=0" |
  jq -e '.limit == 2 and .offset == 0 and (.items | length) <= 2 and all(.items[]; .intent.schemaVersion == 1 and .intent.intentId == .intentId and (.intent.snapshotIds | length) == 1 and (if .intent.leg == "PERP" then .intent.instrument == "SOL-PERP" elif .variant == "jitosol_carry" then .intent.instrument == "JUPITER:JITOSOL-USDC" else .intent.instrument == "JUPITER:SOL-USDC" end))' >/dev/null
curl -fsS "$base_url/v1/fills?limit=2&offset=0" |
  jq -e '.limit == 2 and (.items | length) <= 2' >/dev/null
curl -fsS "$base_url/v1/funding?limit=2&offset=0" |
  jq -e '.limit == 2 and all(.items[]; .amountUsd.scale == 6)' >/dev/null
curl -fsS "$base_url/v1/pnl" |
  jq -e 'length == 4 and all(.[]; .scope == "recorded_attribution_v1")' >/dev/null
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
  jq -e '.executionMode == "paper" and (.adapterMode == "synthetic" or .adapterMode == "authoritative") and .liveEnabled == false and .databaseSchemaVersion == 27 and .targetNotionalUsdMicros == "500000000" and .paperMaximumJitoSolAtoms == "10000000000" and .paperCollateralUsdMicros == "500000000" and .paperCostsUsdMicros == "200000" and .paperRiskHaircutUsdMicros == "50000" and .paperSlippageBps == 50 and .maxSourceAgeMs == 60000 and .minimumMarginRatioPpm == 1500000 and .minimumLiquidationDistanceBps == 1000 and .executionPolicyProfile == "shadow-v1" and .executionIntentTtlMs == 5000 and .maximumExecutionSlippageBps == 50' >/dev/null

test "$(curl -sS -o /dev/null -w '%{http_code}' "$base_url/v1/orders?limit=101")" = "400"
printf 'read API checks passed\n'
