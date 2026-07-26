import { createHash } from "node:crypto";

export type MarketSnapshotPayload = {
  totalPoolLamports: string;
  supplyAtoms: string;
  jitosolAtoms: string;
  notionalUsdMicros: string;
  shortReceiptPpm: string;
  solPriceUsdMicros: string;
  priorNavLamports: string;
  costsUsdMicros: string;
  riskHaircutUsdMicros: string;
};

export type MarketSnapshotEvent = {
  schemaVersion: 1;
  eventId: string;
  eventType: "MarketSnapshot";
  source: string;
  observedAtMs: string;
  sourceSequence: string;
  idempotencyKey: string;
  rawPayloadHash: string;
  payload: MarketSnapshotPayload;
};

const unsignedInteger = /^(0|[1-9][0-9]*)$/;
const signedInteger = /^-?(0|[1-9][0-9]*)$/;
const payloadFields = [
  "totalPoolLamports",
  "supplyAtoms",
  "jitosolAtoms",
  "notionalUsdMicros",
  "shortReceiptPpm",
  "solPriceUsdMicros",
  "priorNavLamports",
  "costsUsdMicros",
  "riskHaircutUsdMicros",
] as const;

function record(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function string(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${field} must be a non-empty string`);
  }
  return value;
}

export function validateEvent(value: unknown): MarketSnapshotEvent {
  const event = record(value, "event");
  if (event.schemaVersion !== 1) throw new Error("unsupported schemaVersion");
  if (event.eventType !== "MarketSnapshot") throw new Error("unsupported eventType");

  for (const field of [
    "eventId",
    "source",
    "observedAtMs",
    "sourceSequence",
    "idempotencyKey",
    "rawPayloadHash",
  ] as const) {
    string(event[field], field);
  }
  if (!unsignedInteger.test(event.observedAtMs as string)) {
    throw new Error("observedAtMs must be an unsigned integer string");
  }
  if (!/^[0-9a-f]{64}$/.test(event.rawPayloadHash as string)) {
    throw new Error("rawPayloadHash must be lowercase SHA-256 hex");
  }

  const payload = record(event.payload, "payload");
  for (const field of payloadFields) {
    const raw = string(payload[field], field);
    const pattern = field === "shortReceiptPpm" ? signedInteger : unsignedInteger;
    if (!pattern.test(raw)) throw new Error(`${field} must be a canonical integer string`);
  }
  return value as MarketSnapshotEvent;
}

export function buildSyntheticEvent(
  sequence: bigint,
  observedAtMs: bigint,
): MarketSnapshotEvent {
  const payload: MarketSnapshotPayload = {
    totalPoolLamports: "12345678900",
    supplyAtoms: "10000000000",
    jitosolAtoms: "2000000000",
    notionalUsdMicros: "500000000",
    shortReceiptPpm: "250",
    solPriceUsdMicros: "150000000",
    priorNavLamports: "1234000000",
    costsUsdMicros: "200000",
    riskHaircutUsdMicros: "50000",
  };
  const rawPayloadHash = createHash("sha256")
    .update(JSON.stringify(payload))
    .digest("hex");
  const id = `synthetic-${sequence}`;
  return validateEvent({
    schemaVersion: 1,
    eventId: id,
    eventType: "MarketSnapshot",
    source: "synthetic-local",
    observedAtMs: observedAtMs.toString(),
    sourceSequence: sequence.toString(),
    idempotencyKey: `synthetic-local:${sequence}`,
    rawPayloadHash,
    payload,
  });
}
