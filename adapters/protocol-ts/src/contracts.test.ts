import assert from "node:assert/strict";
import { test } from "node:test";
import {
  buildSyntheticFundingObservation,
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
  assert.equal(event.payload.epoch, "900");
  assert.equal(event.payload.oracleStatus, "valid");
  assert.equal(event.payload.perpExitDepthLamports, "100000000000");
  assert.equal(event.payload.shortReceiptPpm, "250");
  assert.equal(event.payload.collateralUsdMicros, "200000000");
  assert.equal(event.payload.liquidationDistanceBps, "5000");
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
        payload: { ...event.payload, shortReceiptPpm: "-0" },
      }),
    /shortReceiptPpm/,
  );
  assert.throws(
    () =>
      validateEvent({
        ...event,
        payload: { ...event.payload, rejectRatePpm: "600000", unknownRatePpm: "500000" },
      }),
    /failure rates/,
  );
  assert.throws(
    () =>
      validateEvent({
        ...event,
        payload: { ...event.payload, maintenanceRequirementUsdMicros: "0" },
      }),
    /maintenanceRequirementUsdMicros/,
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
        payload: { ...event.payload, realizedShortRatePpm: "-0" },
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

test("builds a depth-qualified per-asset funding observation", () => {
  const event = buildSyntheticFundingObservation(
    3n,
    1_785_024_000_000n,
    "session-a",
  );

  assert.equal(event.eventType, "FundingObservation");
  assert.equal(event.source, "synthetic-funding:BTC");
  assert.equal(event.sourceSequence, "session-a:scan-3");
  assert.equal(event.payload.scanId, "synthetic-session-a-3");
  assert.equal(event.payload.scanIndex, "0");
  assert.equal(event.payload.scanSize, "1");
  assert.equal(event.payload.venue, "hyperliquid");
  assert.equal(event.payload.asset, "BTC");
  assert.equal(event.payload.fundingRatePpmPerHour, "13");
  assert.equal(event.payload.depthQualified, true);
  assert.equal(event.payload.fundingHistory.length, 1);
  assert.equal(validateEvent(event), event);

  assert.throws(
    () =>
      validateEvent({
        ...event,
        payload: { ...event.payload, scanIndex: "1" },
      }),
    /scanIndex/,
  );
  assert.throws(
    () =>
      validateEvent({
        ...event,
        payload: { ...event.payload, fundingRatePpmPerHour: "-0" },
      }),
    /fundingRatePpmPerHour/,
  );
  assert.throws(
    () =>
      validateEvent({
        ...event,
        payload: { ...event.payload, spotExitDepthAtoms: "0" },
      }),
    /depth-qualified/,
  );
  assert.throws(
    () =>
      validateEvent({
        ...event,
        payload: {
          ...event.payload,
          sourceStatus: "invalid",
          depthQualified: true,
        },
      }),
    /invalid source/,
  );
  assert.throws(
    () =>
      validateEvent({
        ...event,
        payload: {
          ...event.payload,
          fundingHistory: [
            { observedAtMs: event.observedAtMs, ratePpm: "1" },
            { observedAtMs: event.observedAtMs, ratePpm: "2" },
          ],
        },
      }),
    /funding history/,
  );
});
