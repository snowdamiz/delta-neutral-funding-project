import { createHash } from "node:crypto";

type ObjectValue = Record<string, unknown>;

function integer(input: ObjectValue, key: string): bigint {
  const value = input[key];
  if (typeof value !== "string" || !/^-?(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${key} must be a canonical integer string`);
  }
  return BigInt(value);
}

function text(input: ObjectValue, key: string): string {
  const value = input[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${key} must be a non-empty string`);
  }
  return value;
}

function positiveDivisor(value: bigint): bigint {
  if (value <= 0n) throw new Error("fixed-point divisor must be positive");
  return value;
}

function halfEven(numerator: bigint, denominator: bigint): bigint {
  const divisor = positiveDivisor(denominator);
  let quotient = numerator / divisor;
  const remainder = numerator % divisor;
  const magnitude = remainder < 0n ? -remainder : remainder;
  const quotientMagnitude = quotient < 0n ? -quotient : quotient;
  if (
    magnitude * 2n > divisor ||
    (magnitude * 2n === divisor && quotientMagnitude % 2n === 1n)
  ) {
    quotient += numerator < 0n ? -1n : 1n;
  }
  return quotient;
}

function ceilPositive(numerator: bigint, denominator: bigint): bigint {
  const divisor = positiveDivisor(denominator);
  return (numerator + divisor - 1n) / divisor;
}

export function evaluateFixedVector(input: ObjectValue) {
  const nav =
    (integer(input, "totalPoolLamports") * 1_000_000_000n) /
    positiveDivisor(integer(input, "supplyAtoms"));
  const funding =
    (integer(input, "notionalUsdMicros") *
      integer(input, "expectedFundingRatePpm")) /
    1_000_000n;
  const spotEquivalent =
    (integer(input, "spotQuantityAtoms") *
      integer(input, "marketRateLamports")) /
    1_000_000_000n;
  const delta = spotEquivalent - integer(input, "perpShortLamports");
  const deltaMagnitude = delta < 0n ? -delta : delta;
  const deltaBps =
    spotEquivalent === 0n
      ? 0n
      : ceilPositive(deltaMagnitude * 10_000n, spotEquivalent);
  const realizedNotional = halfEven(
    integer(input, "realizedShortQuantityLamports") *
      integer(input, "solPriceUsdMicros"),
    1_000_000_000n,
  );
  const realizedFunding =
    (realizedNotional * integer(input, "realizedShortRatePpm")) /
    1_000_000n;

  return {
    navLamports: nav.toString(),
    fundingUsdMicros: funding.toString(),
    spotEquivalentLamports: spotEquivalent.toString(),
    deltaLamports: delta.toString(),
    deltaBps: deltaBps.toString(),
    realizedFundingUsdMicros: realizedFunding.toString(),
  };
}

export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`;
  }
  if (value !== null && typeof value === "object") {
    return `{${Object.entries(value as ObjectValue)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => `${JSON.stringify(key)}:${canonicalJson(item)}`)
      .join(",")}}`;
  }
  const encoded = JSON.stringify(value);
  if (encoded === undefined) throw new Error("unsupported canonical JSON value");
  return encoded;
}

export function canonicalExecutionIntent(input: ObjectValue): string {
  const snapshots = input.snapshotIds;
  const snapshotIds = Array.isArray(snapshots)
    ? snapshots.map((value) => {
        if (typeof value !== "string" || value.length === 0) {
          throw new Error("snapshotIds must contain non-empty strings");
        }
        return value;
      })
    : [text(input, "snapshotId")];
  if (snapshotIds.length === 0) {
    throw new Error("snapshotIds must not be empty");
  }
  return canonicalJson({
    configHash: text(input, "configHash"),
    expiresAtMs: text(input, "expiresAtMs"),
    instrument: text(input, "instrument"),
    intentId: text(input, "intentId"),
    leg: text(input, "leg"),
    limitPriceAtoms: text(input, "limitPriceAtoms"),
    maxQuantityAtoms: text(input, "maxQuantityAtoms"),
    maxSlippageBps: text(input, "maxSlippageBps"),
    operation: text(input, "operation"),
    policyProfile: text(input, "policyProfile"),
    reduceOnly: input.reduceOnly,
    schemaVersion: 1,
    side: text(input, "side"),
    snapshotIds,
    stateVersion: text(input, "stateVersion"),
    strategyRunId: text(input, "strategyRunId"),
    variant: text(input, "variant"),
  });
}

export function executionIntentHash(input: ObjectValue): string {
  return createHash("sha256")
    .update(canonicalExecutionIntent(input))
    .digest("hex");
}
