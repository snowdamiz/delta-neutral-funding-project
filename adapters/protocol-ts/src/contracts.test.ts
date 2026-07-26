import assert from "node:assert/strict";
import { test } from "node:test";
import {
  buildSyntheticEvent,
  buildSyntheticFundingSettlement,
  validateEvent,
} from "./contracts.js";

test("builds a session-scoped v1 event with integer strings", () => {
  const event = buildSyntheticEvent(7n, 1_785_024_000_000n, "session-a");

  assert.equal(event.schemaVersion, 1);
  assert.equal(event.source, "synthetic-local:session-a");
  assert.equal(event.sourceSequence, "7");
  assert.equal(event.sourceSlot, "320000007");
  assert.equal(event.idempotencyKey, "synthetic-local:session-a:7");
  assert.equal(event.payload.oracleStatus, "valid");
  assert.equal(event.payload.perpExitDepthLamports, "100000000000");
  assert.equal(event.payload.shortReceiptPpm, "250");
  assert.match(event.rawPayloadHash, /^[0-9a-f]{64}$/);
  assert.equal(validateEvent(event), event);

  assert.throws(
    () => validateEvent({ ...event, payload: { ...event.payload, shortReceiptPpm: 250 } }),
    /shortReceiptPpm/,
  );
  assert.throws(
    () => validateEvent({ ...event, payload: { ...event.payload, fillRatePpm: "1000001" } }),
    /fillRatePpm/,
  );
  assert.throws(
    () =>
      validateEvent({
        ...event,
        payload: { ...event.payload, rejectRatePpm: "600000", unknownRatePpm: "500000" },
      }),
    /failure rates/,
  );

  assert.notEqual(
    buildSyntheticEvent(7n, 1_785_024_000_000n, "session-b").idempotencyKey,
    event.idempotencyKey,
  );
});

test("builds a signed-rate funding settlement with a session-scoped payment identity", () => {
  const event = buildSyntheticFundingSettlement(
    12n,
    1_785_024_000_000n,
    "session-a",
  );

  assert.equal(event.eventType, "FundingSettlement");
  assert.equal(event.eventId, "synthetic-funding-session-a-12");
  assert.equal(event.idempotencyKey, "synthetic-local:session-a:funding:12");
  assert.equal(event.payload.venuePaymentId, "synthetic-payment-session-a-12");
  assert.equal(event.payload.effectiveAtMs, event.observedAtMs);
  assert.equal(event.payload.realizedShortRatePpm, "250");
  assert.equal(event.payload.solPriceUsdMicros, "150000000");
  assert.equal(validateEvent(event), event);

  assert.throws(
    () =>
      validateEvent({
        ...event,
        payload: { ...event.payload, realizedShortRatePpm: 250 },
      }),
    /realizedShortRatePpm/,
  );
  assert.throws(
    () =>
      validateEvent({
        ...event,
        payload: { ...event.payload, effectiveAtMs: "1785024000001" },
      }),
    /effectiveAtMs/,
  );
});
