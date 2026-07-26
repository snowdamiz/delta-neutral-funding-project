import { createHash } from "node:crypto";

export type MarketSnapshotPayload = {
  epoch: string;
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
  collateralUsdMicros: string;
  maintenanceRequirementUsdMicros: string;
  liquidationDistanceBps: string;
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

export type FundingSettlementPayload = {
  venuePaymentId: string;
  effectiveAtMs: string;
  realizedShortRatePpm: string;
  solPriceUsdMicros: string;
};

export type FundingSettlementEvent = {
  schemaVersion: 1;
  eventId: string;
  eventType: "FundingSettlement";
  source: string;
  observedAtMs: string;
  sourceSlot: string;
  sourceSequence: string;
  idempotencyKey: string;
  rawPayloadHash: string;
  payload: FundingSettlementPayload;
};

export type ProtocolEvent = MarketSnapshotEvent | FundingSettlementEvent;

const unsignedInteger = /^(0|[1-9][0-9]*)$/;
const signedInteger = /^(0|-?[1-9][0-9]*)$/;
const payloadFields = [
  "epoch",
  "totalPoolLamports",
  "supplyAtoms",
  "jitosolAtoms",
  "notionalUsdMicros",
  "shortReceiptPpm",
  "solPriceUsdMicros",
  "priorNavLamports",
  "costsUsdMicros",
  "riskHaircutUsdMicros",
  "collateralUsdMicros",
  "maintenanceRequirementUsdMicros",
  "liquidationDistanceBps",
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

export function validateEvent(value: unknown): ProtocolEvent {
  const event = record(value, "event");
  if (event.schemaVersion !== 1) throw new Error("unsupported schemaVersion");

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
  if (event.eventType === "FundingSettlement") {
    string(payload.venuePaymentId, "venuePaymentId");
    const effectiveAtMs = string(payload.effectiveAtMs, "effectiveAtMs");
    const realizedShortRatePpm = string(
      payload.realizedShortRatePpm,
      "realizedShortRatePpm",
    );
    const solPriceUsdMicros = string(payload.solPriceUsdMicros, "solPriceUsdMicros");
    if (!unsignedInteger.test(effectiveAtMs)) {
      throw new Error("effectiveAtMs must be an unsigned integer string");
    }
    if (BigInt(effectiveAtMs) > BigInt(event.observedAtMs as string)) {
      throw new Error("effectiveAtMs cannot be in the future");
    }
    if (!signedInteger.test(realizedShortRatePpm)) {
      throw new Error("realizedShortRatePpm must be a canonical integer string");
    }
    if (
      BigInt(realizedShortRatePpm) < -1_000_000n ||
      BigInt(realizedShortRatePpm) > 1_000_000n
    ) {
      throw new Error("realizedShortRatePpm must be between -1000000 and 1000000");
    }
    if (!unsignedInteger.test(solPriceUsdMicros) || BigInt(solPriceUsdMicros) === 0n) {
      throw new Error("solPriceUsdMicros must be a positive integer string");
    }
    return value as FundingSettlementEvent;
  }
  if (event.eventType !== "MarketSnapshot") throw new Error("unsupported eventType");
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
  if (BigInt(payload.maintenanceRequirementUsdMicros as string) === 0n) {
    throw new Error("maintenanceRequirementUsdMicros must be positive");
  }
  return value as MarketSnapshotEvent;
}

export function buildSyntheticEvent(
  sequence: bigint,
  observedAtMs: bigint,
  sessionId: string,
): MarketSnapshotEvent {
  const payload: MarketSnapshotPayload = {
    epoch: "900",
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
    collateralUsdMicros: "200000000",
    maintenanceRequirementUsdMicros: "50000000",
    liquidationDistanceBps: "5000",
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
  const source = `synthetic-local:${sessionId}`;
  const id = `synthetic-${sessionId}-${sequence}`;
  return validateEvent({
    schemaVersion: 1,
    eventId: id,
    eventType: "MarketSnapshot",
    source,
    observedAtMs: observedAtMs.toString(),
    sourceSlot: (320_000_000n + sequence).toString(),
    sourceSequence: sequence.toString(),
    idempotencyKey: `${source}:${sequence}`,
    rawPayloadHash,
    payload,
  }) as MarketSnapshotEvent;
}

export function buildSyntheticFundingSettlement(
  sequence: bigint,
  observedAtMs: bigint,
  sessionId: string,
): FundingSettlementEvent {
  const payload: FundingSettlementPayload = {
    venuePaymentId: `synthetic-payment-${sessionId}-${sequence}`,
    effectiveAtMs: observedAtMs.toString(),
    realizedShortRatePpm: "250",
    solPriceUsdMicros: "150000000",
  };
  const source = `synthetic-local:${sessionId}`;
  return validateEvent({
    schemaVersion: 1,
    eventId: `synthetic-funding-${sessionId}-${sequence}`,
    eventType: "FundingSettlement",
    source,
    observedAtMs: observedAtMs.toString(),
    sourceSlot: (320_000_000n + sequence).toString(),
    sourceSequence: sequence.toString(),
    idempotencyKey: `${source}:funding:${sequence}`,
    rawPayloadHash: createHash("sha256").update(JSON.stringify(payload)).digest("hex"),
    payload,
  }) as FundingSettlementEvent;
}
