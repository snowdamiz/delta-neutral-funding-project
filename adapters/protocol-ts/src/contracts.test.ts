import assert from "node:assert/strict";
import { test } from "node:test";
import { buildSyntheticEvent, validateEvent } from "./contracts.js";

test("builds a signed-boundary-safe v1 event with integer strings", () => {
  const event = buildSyntheticEvent(7n, 1_785_024_000_000n);

  assert.equal(event.schemaVersion, 1);
  assert.equal(event.sourceSequence, "7");
  assert.equal(event.sourceSlot, "320000007");
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
});
