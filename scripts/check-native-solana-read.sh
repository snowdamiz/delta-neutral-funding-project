#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
config=$(curl -fsS "${COLLECTOR_URL:-http://127.0.0.1:8080}/v1/config")

test "$(printf '%s' "$config" | jq -r .adapterMode)" = authoritative || {
  printf 'native Solana differential requires authoritative adapter mode\n' >&2
  exit 1
}

native=$("$project_dir/bin/collector" solana-read)
printf '%s' "$native" |
  jq -e '
    .schemaVersion == 1 and
    .source == "mesh-native-solana" and
    .commitment == "confirmed" and
    .poolAddress == "Jito4APyf642JPZPx3hGc6WWJ8zPKtRbRs4P815Awbb" and
    .mintAddress == "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn" and
    .programStatus == "valid" and
    (.epoch | test("^[0-9]+$")) and
    (.totalPoolLamports | test("^[1-9][0-9]*$")) and
    (.supplyAtoms | test("^[1-9][0-9]*$")) and
    (.navLamports | test("^[1-9][0-9]*$")) and
    ((.accountsSlot | tonumber) - (.epochAbsoluteSlot | tonumber) | fabs) <= 5000
  ' >/dev/null

adapter=$(
  docker compose --project-directory "$project_dir" exec -T postgres \
    psql -U funding -d funding -Atc "
      SELECT json_build_object(
        'epoch', canonical_payload #>> '{payload,epoch}',
        'totalPoolLamports', canonical_payload #>> '{payload,totalPoolLamports}',
        'supplyAtoms', canonical_payload #>> '{payload,supplyAtoms}',
        'navLamports', trunc(
          (canonical_payload #>> '{payload,totalPoolLamports}')::numeric *
          1000000000 /
          (canonical_payload #>> '{payload,supplyAtoms}')::numeric
        )::text,
        'observedAtMs', observed_at_ms::text
      )
      FROM normalized_events
      WHERE event_type = 'MarketSnapshot'
        AND source LIKE 'authoritative:%'
      ORDER BY observed_at_ms DESC
      LIMIT 1
    "
)

jq -n -e \
  --argjson native "$native" \
  --argjson adapter "$adapter" '
    $native.epoch == $adapter.epoch and
    $native.navLamports == $adapter.navLamports
  ' >/dev/null

jq -n \
  --argjson native "$native" \
  --argjson adapter "$adapter" '{
    status: "passed",
    native: $native,
    adapter: $adapter,
    exactEpochMatch: ($native.epoch == $adapter.epoch),
    exactNavMatch: ($native.navLamports == $adapter.navLamports),
    exactPoolStateMatch: (
      $native.totalPoolLamports == $adapter.totalPoolLamports and
      $native.supplyAtoms == $adapter.supplyAtoms
    )
  }'
