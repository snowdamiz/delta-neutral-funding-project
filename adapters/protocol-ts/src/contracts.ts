import { createHash } from "node:crypto";

export type MarketSnapshotPayload = {
  epoch: string;
  oracleStatus: "valid" | "invalid";
  totalPoolLamports: string;
  supplyAtoms: string;
  jitosolAtoms: string;
  notionalUsdMicros: string;
  shortReceiptPpm: string;
  rewardRatePpmPerHour: string;
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

export type FundingObservationPayload = {
  scanId: string;
  scanIndex: string;
  scanSize: string;
  venue: string;
  asset: string;
  instrument: string;
  sourceObservedAtMs: string;
  sourceStatus: "valid" | "invalid";
  fundingRatePpmPerHour: string;
  fundingHistory: { observedAtMs: string; ratePpm: string }[];
  realizedFundingRatePpm: string;
  realizedFundingAtMs: string;
  markPriceUsdMicros: string;
  openInterestUsdMicros: string;
  spotBidPriceUsdMicros: string;
  spotAskPriceUsdMicros: string;
  perpBidPriceUsdMicros: string;
  perpAskPriceUsdMicros: string;
  spotExitDepthAtoms: string;
  perpExitDepthAtoms: string;
  depthQualified: boolean;
  borrowVenue: string;
  borrowMarket: string;
  borrowReserve: string;
  borrowMint: string;
  borrowSourceObservedAtMs: string;
  borrowSourceStatus: "valid" | "invalid" | "unavailable";
  borrowRatePpmPerHour: string;
  borrowAvailableUsdMicros: string;
  borrowUtilizationPpm: string;
};

export type FundingObservationEvent = {
  schemaVersion: 1;
  eventId: string;
  eventType: "FundingObservation";
  source: string;
  observedAtMs: string;
  sourceSlot: string;
  sourceSequence: string;
  idempotencyKey: string;
  rawPayloadHash: string;
  payload: FundingObservationPayload;
};

export type ProtocolEvent =
  | MarketSnapshotEvent
  | FundingSettlementEvent
  | FundingObservationEvent;

const unsignedInteger = /^(0|[1-9][0-9]*)$/;
const signedInteger = /^(0|-?[1-9][0-9]*)$/;
const payloadFields = [
  "epoch",
  "totalPoolLamports",
  "supplyAtoms",
  "jitosolAtoms",
  "notionalUsdMicros",
  "shortReceiptPpm",
  "rewardRatePpmPerHour",
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
  "rewardRatePpmPerHour",
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
  if (event.eventType === "FundingObservation") {
    const scanId = string(payload.scanId, "scanId");
    const venue = string(payload.venue, "venue");
    const asset = string(payload.asset, "asset");
    string(payload.instrument, "instrument");
    if (!/^[A-Za-z0-9:_-]{1,200}$/.test(scanId)) {
      throw new Error("scanId has invalid characters");
    }
    if (!/^[a-z0-9_-]{1,32}$/.test(venue)) {
      throw new Error("venue must be a lowercase identifier");
    }
    if (!/^[A-Z0-9]{1,24}$/.test(asset)) {
      throw new Error("asset must be an uppercase identifier");
    }
    for (const field of [
      "scanIndex",
      "scanSize",
      "sourceObservedAtMs",
      "realizedFundingAtMs",
      "markPriceUsdMicros",
      "openInterestUsdMicros",
      "spotBidPriceUsdMicros",
      "spotAskPriceUsdMicros",
      "perpBidPriceUsdMicros",
      "perpAskPriceUsdMicros",
      "spotExitDepthAtoms",
      "perpExitDepthAtoms",
      "borrowSourceObservedAtMs",
      "borrowRatePpmPerHour",
      "borrowAvailableUsdMicros",
      "borrowUtilizationPpm",
    ] as const) {
      const raw = string(payload[field], field);
      if (!unsignedInteger.test(raw)) {
        throw new Error(`${field} must be an unsigned integer string`);
      }
    }
    const rate = string(
      payload.fundingRatePpmPerHour,
      "fundingRatePpmPerHour",
    );
    if (!signedInteger.test(rate)) {
      throw new Error(
        "fundingRatePpmPerHour must be a canonical integer string",
      );
    }
    if (BigInt(rate) < -1_000_000n || BigInt(rate) > 1_000_000n) {
      throw new Error(
        "fundingRatePpmPerHour must be between -1000000 and 1000000",
      );
    }
    if (!Array.isArray(payload.fundingHistory) || payload.fundingHistory.length === 0) {
      throw new Error("funding history must contain at least one sample");
    }
    let previousHistoryAt = -1n;
    for (const [index, value] of payload.fundingHistory.entries()) {
      if (typeof value !== "object" || value === null || Array.isArray(value)) {
        throw new Error(`funding history ${index} must be an object`);
      }
      const sample = value as Record<string, unknown>;
      const at = string(sample.observedAtMs, `funding history ${index} observedAtMs`);
      const sampleRate = string(sample.ratePpm, `funding history ${index} ratePpm`);
      if (
        !unsignedInteger.test(at) ||
        !signedInteger.test(sampleRate) ||
        BigInt(sampleRate) < -1_000_000n ||
        BigInt(sampleRate) > 1_000_000n ||
        BigInt(at) <= previousHistoryAt ||
        BigInt(at) > BigInt(event.observedAtMs as string)
      ) {
        throw new Error("funding history must be ordered, bounded, and not in the future");
      }
      previousHistoryAt = BigInt(at);
    }
    const realizedRate = string(
      payload.realizedFundingRatePpm,
      "realizedFundingRatePpm",
    );
    if (
      !signedInteger.test(realizedRate) ||
      BigInt(realizedRate) < -1_000_000n ||
      BigInt(realizedRate) > 1_000_000n
    ) {
      throw new Error(
        "realizedFundingRatePpm must be between -1000000 and 1000000",
      );
    }
    const scanIndex = BigInt(payload.scanIndex as string);
    const scanSize = BigInt(payload.scanSize as string);
    if (scanSize === 0n || scanIndex >= scanSize) {
      throw new Error("scanIndex must be less than positive scanSize");
    }
    if (
      payload.sourceStatus !== "valid" &&
      payload.sourceStatus !== "invalid"
    ) {
      throw new Error("sourceStatus must be valid or invalid");
    }
    if (typeof payload.depthQualified !== "boolean") {
      throw new Error("depthQualified must be a boolean");
    }
    if (payload.sourceStatus === "invalid" && payload.depthQualified) {
      throw new Error("invalid source cannot be depth-qualified");
    }
    if (payload.sourceStatus === "valid") {
      for (const field of [
        "markPriceUsdMicros",
        "perpBidPriceUsdMicros",
        "perpAskPriceUsdMicros",
      ] as const) {
        if (BigInt(payload[field] as string) === 0n) {
          throw new Error(`${field} must be positive for a valid source`);
        }
      }
    }
    if (
      payload.depthQualified &&
      [
        "spotBidPriceUsdMicros",
        "spotAskPriceUsdMicros",
        "spotExitDepthAtoms",
        "perpExitDepthAtoms",
      ].some((field) => BigInt(payload[field] as string) === 0n)
    ) {
      throw new Error("depth-qualified observations require executable spot and perp depth");
    }
    const borrowStatus = payload.borrowSourceStatus;
    if (
      borrowStatus !== "valid" &&
      borrowStatus !== "invalid" &&
      borrowStatus !== "unavailable"
    ) {
      throw new Error("borrowSourceStatus must be valid, invalid, or unavailable");
    }
    for (const field of [
      "borrowVenue",
      "borrowMarket",
      "borrowReserve",
      "borrowMint",
    ] as const) {
      string(payload[field], field);
    }
    const borrowRate = BigInt(payload.borrowRatePpmPerHour as string);
    const borrowUtilization = BigInt(payload.borrowUtilizationPpm as string);
    if (borrowRate > 1_000_000n || borrowUtilization > 1_000_000n) {
      throw new Error("borrow rates must be between zero and one million ppm");
    }
    if (borrowStatus === "valid") {
      if (
        payload.borrowVenue !== "kamino" ||
        !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(payload.borrowMarket as string) ||
        !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(payload.borrowReserve as string) ||
        !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(payload.borrowMint as string) ||
        BigInt(payload.borrowSourceObservedAtMs as string) === 0n ||
        BigInt(payload.borrowSourceObservedAtMs as string) >
          BigInt(event.observedAtMs as string)
      ) {
        throw new Error("valid borrow snapshot has invalid identity or time");
      }
    } else if (
      borrowRate !== 0n ||
      BigInt(payload.borrowAvailableUsdMicros as string) !== 0n ||
      borrowUtilization !== 0n
    ) {
      throw new Error("unusable borrow snapshot must carry zero economics");
    }
    return value as FundingObservationEvent;
  }
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
    rewardRatePpmPerHour: "0",
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

export function buildSyntheticFundingObservation(
  sequence: bigint,
  observedAtMs: bigint,
  sessionId: string,
): FundingObservationEvent {
  const scanId = `synthetic-${sessionId}-${sequence}`;
  const payload: FundingObservationPayload = {
    scanId,
    scanIndex: "0",
    scanSize: "1",
    venue: "hyperliquid",
    asset: "BTC",
    instrument: "BTC-PERP",
    sourceObservedAtMs: observedAtMs.toString(),
    sourceStatus: "valid",
    fundingRatePpmPerHour: "13",
    fundingHistory: [{ observedAtMs: observedAtMs.toString(), ratePpm: "13" }],
    realizedFundingRatePpm: "13",
    realizedFundingAtMs: observedAtMs.toString(),
    markPriceUsdMicros: "65000000000",
    openInterestUsdMicros: "1000000000000",
    spotBidPriceUsdMicros: "64990000000",
    spotAskPriceUsdMicros: "65010000000",
    perpBidPriceUsdMicros: "64995000000",
    perpAskPriceUsdMicros: "65005000000",
    spotExitDepthAtoms: "100000000",
    perpExitDepthAtoms: "100000000",
    depthQualified: true,
    borrowVenue: "none",
    borrowMarket: "none",
    borrowReserve: "none",
    borrowMint: "none",
    borrowSourceObservedAtMs: "0",
    borrowSourceStatus: "unavailable",
    borrowRatePpmPerHour: "0",
    borrowAvailableUsdMicros: "0",
    borrowUtilizationPpm: "0",
  };
  const source = "synthetic-funding:BTC";
  return validateEvent({
    schemaVersion: 1,
    eventId: `${scanId}:hyperliquid:BTC`,
    eventType: "FundingObservation",
    source,
    observedAtMs: observedAtMs.toString(),
    sourceSlot: observedAtMs.toString(),
    sourceSequence: `${sessionId}:scan-${sequence}`,
    idempotencyKey: `${source}:${scanId}`,
    rawPayloadHash: createHash("sha256")
      .update(JSON.stringify(payload))
      .digest("hex"),
    payload,
  }) as FundingObservationEvent;
}
