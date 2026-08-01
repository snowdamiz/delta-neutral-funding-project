#!/bin/sh
set -eu

base_url=${1:-http://127.0.0.1:8080}
secret=${OPERATOR_HMAC_SECRET:-local-operator-only-change-me}
run_id="operator-api-$(date +%s)-$$"

test "$(
  curl -sS -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' \
    --data '{"reason":"must be rejected"}' \
    "$base_url/v1/pause-all"
)" = "401"

signature() {
  printf '%s\n%s' "$1" "$2" |
    openssl dgst -sha256 -hmac "$secret" -hex |
    awk '{print $NF}'
}

post() {
  action=$1
  idempotency_key=$2
  body=$3
  curl -fsS \
    -H 'content-type: application/json' \
    -H "x-idempotency-key: $idempotency_key" \
    -H "x-operator-signature: $(signature "$idempotency_key" "$body")" \
    --data "$body" \
    "$base_url/v1/$action"
}

pause_key="$run_id-pause"
pause_body='{"reason":"operator API check"}'
post pause-entries "$pause_key" "$pause_body" |
  jq -e '.status == "applied" and .pauseEntries == true and .duplicate == false' >/dev/null
post pause-entries "$pause_key" "$pause_body" |
  jq -e '.duplicate == true' >/dev/null

conflict_body='{"reason":"different operator API check"}'
test "$(
  curl -sS -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' \
    -H "x-idempotency-key: $pause_key" \
    -H "x-operator-signature: $(signature "$pause_key" "$conflict_body")" \
    --data "$conflict_body" \
    "$base_url/v1/pause-entries"
)" = "409"

post pause-all "$run_id-pause-all" '{"reason":"operator kill-switch check"}' |
  jq -e '.pauseEntries == true and .pauseAll == true' >/dev/null
post resume "$run_id-resume" '{"reason":"paper reconciliation passed"}' |
  jq -e '.pauseEntries == false and .pauseAll == false and (.reconciliationId | length) > 0' >/dev/null
post reconcile "$run_id-reconcile" '{"reason":"standalone paper reconciliation"}' |
  jq -e '(.reconciliationId | length) > 0' >/dev/null

for strategy in solana_wallet_flow_quant; do
  key="$run_id-$strategy-empty"
  body='{"reason":"empty wallet cohort must fail closed"}'
  test "$(
    curl -sS -o /dev/null -w '%{http_code}' \
      -H 'content-type: application/json' \
      -H "x-idempotency-key: $key" \
      -H "x-operator-signature: $(signature "$key" "$body")" \
      --data "$body" \
      "$base_url/v1/strategies/$strategy/start"
  )" = "409"
done

post strategies/cross_asset_funding/stop "$run_id-cross-stop-first" \
  '{"reason":"isolation setup"}' >/dev/null
post strategies/negative_funding_reverse/stop "$run_id-reverse-stop" \
  '{"reason":"isolation setup"}' >/dev/null
post strategies/cross_asset_funding/start "$run_id-cross-start" \
  '{"reason":"independent strategy check"}' |
  jq -e '.strategy == "cross_asset_funding" and .enabled == true' >/dev/null
curl -fsS "$base_url/v1/strategies" |
  jq -e '([.strategies[] | select(.enabled) | .id] == ["cross_asset_funding"])' >/dev/null
post strategies/cross_asset_funding/stop "$run_id-cross-stop" \
  '{"reason":"independent strategy check complete"}' |
  jq -e '.strategy == "cross_asset_funding" and .enabled == false' >/dev/null

# Live arm/disarm is precondition-guarded: arming a stopped strategy with an
# empty cohort fails closed, and disarm always succeeds.
key="$run_id-arm-live-blocked"
body='{"mode":"live","approval":"ARM LIVE TRADING","reason":"arm must fail closed"}'
test "$(
  curl -sS -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' \
    -H "x-idempotency-key: $key" \
    -H "x-operator-signature: $(signature "$key" "$body")" \
    --data "$body" \
    "$base_url/v1/strategies/solana_wallet_flow_quant/mode"
)" = "409"
post strategies/solana_wallet_flow_quant/mode "$run_id-disarm-live" \
  '{"mode":"paper","reason":"disarm is always accepted"}' |
  jq -e '.mode == "paper"' >/dev/null

curl -fsS "$base_url/v1/status" |
  jq -e '.paused == false and .pauseEntries == false and .pauseAll == false' >/dev/null

printf 'operator API checks passed\n'
