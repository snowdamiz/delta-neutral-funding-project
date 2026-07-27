#!/bin/sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
subscription=$("$project_dir/bin/collector" solana-subscribe)
read=$("$project_dir/bin/collector" solana-read)

printf '%s' "$subscription" |
  jq -e '
    .schemaVersion == 1 and
    .source == "mesh-native-solana-ws" and
    .status == "valid" and
    (.subscription | type) == "number" and
    (.slot | test("^[1-9][0-9]*$")) and
    (.parent | test("^[1-9][0-9]*$")) and
    (.root | test("^[1-9][0-9]*$")) and
    ((.slot | tonumber) > (.parent | tonumber)) and
    ((.parent | tonumber) >= (.root | tonumber))
  ' >/dev/null

ws_slot=$(printf '%s' "$subscription" | jq -er '.slot | tonumber')
http_slot=$(printf '%s' "$read" | jq -er '.accountsSlot | tonumber')
slot_drift=$((ws_slot - http_slot))
if [ "$slot_drift" -lt 0 ]; then
  slot_drift=$((-slot_drift))
fi
test "$slot_drift" -le 5000

jq -n \
  --argjson subscription "$subscription" \
  --argjson read "$read" \
  --arg slotDrift "$slot_drift" \
  '{
    status: "passed",
    subscription: $subscription,
    read: $read,
    slotDrift: $slotDrift
  }'
