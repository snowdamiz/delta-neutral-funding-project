import { createHash } from "node:crypto";

export type MarketSnapshotPayload = {
  oracleStatus: "valid" | "invalid";
  totalPoolLamports: string;
  supplyAtoms: string;
  jitosolAtoms: string;
  notionalUsdMicros: string;
  shortReceiptPpm: string;
  solPriceUsdMicros: string;
  priorNavLamports: string;
  costsUsdMicros: string;
  riskHaircutUsdMicros: string;
  solSpotBidPriceUsdMicros: string;
  solSpotAskPriceUsdMicros: string;
  jitosolSpotBidPriceUsdMicros: string;
  jitosolSpotAskPriceUsdMicros: string;
  perpBidPriceUsdMicros: string;
  perpAskPriceUsdMicros: string;
  solExitDepthLamports: string;
  jitosolExitDepthLamports: string;
  perpExitDepthLamports: string;
  fillRatePpm: string;
  slippagePpm: string;
  spotFeePpm: string;
  perpFeePpm: string;
  rejectRatePpm: string;
  unknownRatePpm: string;
};

export type MarketSnapshotEvent = {
  schemaVersion: 1;
  eventId: string;
  eventType: "MarketSnapshot";
  source: string;
  observedAtMs: string;
  sourceSlot: string;
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
  "solSpotBidPriceUsdMicros",
  "solSpotAskPriceUsdMicros",
  "jitosolSpotBidPriceUsdMicros",
  "jitosolSpotAskPriceUsdMicros",
  "perpBidPriceUsdMicros",
  "perpAskPriceUsdMicros",
  "solExitDepthLamports",
  "jitosolExitDepthLamports",
  "perpExitDepthLamports",
  "fillRatePpm",
  "slippagePpm",
  "spotFeePpm",
  "perpFeePpm",
  "rejectRatePpm",
  "unknownRatePpm",
] as const;
const boundedRates = [
  "fillRatePpm",
  "slippagePpm",
  "spotFeePpm",
  "perpFeePpm",
  "rejectRatePpm",
  "unknownRatePpm",
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
    "sourceSlot",
    "sourceSequence",
    "idempotencyKey",
    "rawPayloadHash",
  ] as const) {
    string(event[field], field);
  }
  if (!unsignedInteger.test(event.observedAtMs as string)) {
    throw new Error("observedAtMs must be an unsigned integer string");
  }
  if (!unsignedInteger.test(event.sourceSlot as string)) {
    throw new Error("sourceSlot must be an unsigned integer string");
  }
  if (!/^[0-9a-f]{64}$/.test(event.rawPayloadHash as string)) {
    throw new Error("rawPayloadHash must be lowercase SHA-256 hex");
  }

  const payload = record(event.payload, "payload");
  if (payload.oracleStatus !== "valid" && payload.oracleStatus !== "invalid") {
    throw new Error("oracleStatus must be valid or invalid");
  }
  for (const field of payloadFields) {
    const raw = string(payload[field], field);
    const pattern = field === "shortReceiptPpm" ? signedInteger : unsignedInteger;
    if (!pattern.test(raw)) throw new Error(`${field} must be a canonical integer string`);
  }
  for (const field of boundedRates) {
    if (BigInt(payload[field] as string) > 1_000_000n) {
      throw new Error(`${field} must be between zero and one million ppm`);
    }
  }
  if (
    BigInt(payload.rejectRatePpm as string) + BigInt(payload.unknownRatePpm as string) >
    1_000_000n
  ) {
    throw new Error("paper failure rates exceed one million ppm");
  }
  return value as MarketSnapshotEvent;
}

export function buildSyntheticEvent(
  sequence: bigint,
  observedAtMs: bigint,
): MarketSnapshotEvent {
  const payload: MarketSnapshotPayload = {
    oracleStatus: "valid",
    totalPoolLamports: "12345678900",
    supplyAtoms: "10000000000",
    jitosolAtoms: "2000000000",
    notionalUsdMicros: "500000000",
    shortReceiptPpm: "250",
    solPriceUsdMicros: "150000000",
    priorNavLamports: "1234000000",
    costsUsdMicros: "200000",
    riskHaircutUsdMicros: "50000",
    solSpotBidPriceUsdMicros: "149950000",
    solSpotAskPriceUsdMicros: "150050000",
    jitosolSpotBidPriceUsdMicros: "185050000",
    jitosolSpotAskPriceUsdMicros: "185250000",
    perpBidPriceUsdMicros: "149980000",
    perpAskPriceUsdMicros: "150020000",
    solExitDepthLamports: "50000000000",
    jitosolExitDepthLamports: "30000000000",
    perpExitDepthLamports: "100000000000",
    fillRatePpm: "1000000",
    slippagePpm: "500",
    spotFeePpm: "500",
    perpFeePpm: "400",
    rejectRatePpm: "0",
    unknownRatePpm: "0",
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
    sourceSlot: (320_000_000n + sequence).toString(),
    sourceSequence: sequence.toString(),
    idempotencyKey: `synthetic-local:${sequence}`,
    rawPayloadHash,
    payload,
  });
}
