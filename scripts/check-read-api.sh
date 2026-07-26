#!/bin/sh
set -eu

base_url=${1:-http://127.0.0.1:8080}

curl -fsS "$base_url/v1/status" |
  jq -e '.executionMode == "paper" and .signerReachable == false' >/dev/null
curl -fsS "$base_url/v1/portfolios" |
  jq -e 'length == 2 and all(.[]; .initialCapitalUsd.scale == 6)' >/dev/null
curl -fsS "$base_url/v1/portfolios/local-sol-control" |
  jq -e '.id == "local-sol-control"' >/dev/null
curl -fsS "$base_url/v1/positions" |
  jq -e 'length == 2 and all(.[]; .spotQuantity.scale == 9 and .marginSnapshot.collateralUsd.scale == 6 and .marginSnapshot.marginRatioPpm == "4000000")' >/dev/null
curl -fsS "$base_url/v1/orders?limit=2&offset=0" |
  jq -e '.limit == 2 and .offset == 0 and (.items | length) <= 2' >/dev/null
curl -fsS "$base_url/v1/fills?limit=2&offset=0" |
  jq -e '.limit == 2 and (.items | length) <= 2' >/dev/null
curl -fsS "$base_url/v1/funding?limit=2&offset=0" |
  jq -e '.limit == 2 and all(.items[]; .amountUsd.scale == 6)' >/dev/null
curl -fsS "$base_url/v1/pnl" |
  jq -e 'length == 2 and all(.[]; .scope == "recorded_attribution_v1")' >/dev/null
curl -fsS "$base_url/v1/pnl/comparison" |
  jq -e '.jitosolIncrementalNetRecordedUsd.scale == 6' >/dev/null
curl -fsS "$base_url/v1/config" |
  jq -e '.executionMode == "paper" and .liveEnabled == false and .minimumMarginRatioPpm == 1500000 and .minimumLiquidationDistanceBps == 1000' >/dev/null

test "$(curl -sS -o /dev/null -w '%{http_code}' "$base_url/v1/orders?limit=101")" = "400"
printf 'read API checks passed\n'
