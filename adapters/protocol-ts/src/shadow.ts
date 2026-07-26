import { createHash } from "node:crypto";
import { canonicalJson, executionIntentHash } from "./conformance.js";

type ObjectValue = Record<string, unknown>;

export type AccountDelta = {
  account: string;
  asset: string;
  deltaAtoms: string;
};

export type ShadowAction = {
  schemaVersion: 1;
  commandId: string;
  intentHash: string;
  programIds: string[];
  accounts: string[];
  market: string;
  mint: string;
  destination: string;
  quantityAtoms: string;
  limitPriceAtoms: string;
  priorityFeeLamports: string;
  computeUnitLimit: string;
  simulateOnly: true;
  submit: false;
  messageHash: string;
  simulatedQuantityAtoms: string;
  simulatedAveragePriceAtoms: string;
  simulatedFeeAtoms: string;
  computeUnitsConsumed: string;
  accountDeltas: AccountDelta[];
};

const intentKeys = [
  "schemaVersion",
  "intentId",
  "strategyRunId",
  "stateVersion",
  "variant",
  "operation",
  "leg",
  "instrument",
  "side",
  "maxQuantityAtoms",
  "limitPriceAtoms",
  "maxSlippageBps",
  "reduceOnly",
  "expiresAtMs",
  "policyProfile",
  "snapshotIds",
  "configHash",
] as const;

const simulationKeys = [
  "schemaVersion",
  "simulationId",
  "programIds",
  "accounts",
  "market",
  "mint",
  "destination",
  "quantityAtoms",
  "averagePriceAtoms",
  "priorityFeeLamports",
  "computeUnitLimit",
  "computeUnitsConsumed",
  "feeAtoms",
  "accountDeltas",
] as const;

function exact(input: ObjectValue, keys: readonly string[], label: string) {
  if (
    Object.keys(input).length !== keys.length ||
    keys.some((key) => !Object.hasOwn(input, key))
  ) {
    throw new Error(`${label} has unknown or missing fields`);
  }
}

function record(value: unknown, field: string): ObjectValue {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as ObjectValue;
}

function text(input: ObjectValue, field: string): string {
  const value = input[field];
  if (typeof value !== "string" || value.length === 0 || value.trim() !== value) {
    throw new Error(`${field} must be a non-empty canonical string`);
  }
  return value;
}

function unsigned(input: ObjectValue, field: string): string {
  const value = input[field];
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${field} must be a canonical unsigned integer string`);
  }
  return value;
}

function positive(input: ObjectValue, field: string): string {
  const value = unsigned(input, field);
  if (value === "0") throw new Error(`${field} must be positive`);
  return value;
}

function textList(input: ObjectValue, field: string): string[] {
  const value = input[field];
  if (
    !Array.isArray(value) ||
    value.length === 0 ||
    value.some(
      (item) =>
        typeof item !== "string" ||
        item.length === 0 ||
        item.trim() !== item,
    )
  ) {
    throw new Error(`${field} must contain non-empty canonical strings`);
  }
  const strings = value as string[];
  if (new Set(strings).size !== strings.length) {
    throw new Error(`${field} must not contain duplicates`);
  }
  return strings;
}

function choice(
  input: ObjectValue,
  field: string,
  values: readonly string[],
): string {
  const value = text(input, field);
  if (!values.includes(value)) throw new Error(`${field} is unsupported`);
  return value;
}

function schemaOne(input: ObjectValue) {
  if (input.schemaVersion !== 1) {
    throw new Error("schemaVersion must be 1");
  }
}

function validateIntent(input: ObjectValue) {
  exact(input, intentKeys, "execution intent");
  schemaOne(input);
  text(input, "intentId");
  text(input, "strategyRunId");
  unsigned(input, "stateVersion");
  choice(input, "variant", ["sol_control", "jitosol_carry"]);
  choice(input, "operation", [
    "OPEN",
    "REBALANCE",
    "CLOSE",
    "EMERGENCY_FLATTEN",
  ]);
  choice(input, "leg", ["SPOT", "PERP"]);
  text(input, "instrument");
  choice(input, "side", ["BUY", "SELL"]);
  positive(input, "maxQuantityAtoms");
  positive(input, "limitPriceAtoms");
  if (BigInt(unsigned(input, "maxSlippageBps")) > 10_000n) {
    throw new Error("maxSlippageBps exceeds 10000");
  }
  if (typeof input.reduceOnly !== "boolean") {
    throw new Error("reduceOnly must be a boolean");
  }
  positive(input, "expiresAtMs");
  text(input, "policyProfile");
  textList(input, "snapshotIds");
  if (!/^[0-9a-f]{64}$/.test(text(input, "configHash"))) {
    throw new Error("configHash must be a SHA-256 hash");
  }
}

function accountDeltas(input: ObjectValue, accounts: string[]): AccountDelta[] {
  const values = input.accountDeltas;
  if (!Array.isArray(values) || values.length === 0) {
    throw new Error("accountDeltas must not be empty");
  }
  return values.map((value) => {
    const delta = record(value, "accountDelta");
    exact(delta, ["account", "asset", "deltaAtoms"], "accountDelta");
    const account = text(delta, "account");
    const asset = text(delta, "asset");
    const deltaAtoms = text(delta, "deltaAtoms");
    if (!/^(0|-?[1-9][0-9]*)$/.test(deltaAtoms)) {
      throw new Error("deltaAtoms must be a canonical signed integer string");
    }
    if (!accounts.includes(account)) {
      throw new Error("accountDelta references an undeclared account");
    }
    return { account, asset, deltaAtoms };
  });
}

export function buildShadowAction(
  intentValue: unknown,
  simulationValue: unknown,
): ShadowAction {
  const intent = record(intentValue, "execution intent");
  const simulation = record(simulationValue, "simulation");
  validateIntent(intent);
  exact(simulation, simulationKeys, "simulation");
  schemaOne(simulation);

  const programIds = textList(simulation, "programIds");
  const accounts = textList(simulation, "accounts");
  const market = text(simulation, "market");
  const mint = text(simulation, "mint");
  const destination = text(simulation, "destination");
  const quantityAtoms = positive(simulation, "quantityAtoms");
  const averagePriceAtoms = positive(simulation, "averagePriceAtoms");
  const priorityFeeLamports = unsigned(simulation, "priorityFeeLamports");
  const computeUnitLimit = positive(simulation, "computeUnitLimit");
  const computeUnitsConsumed = positive(simulation, "computeUnitsConsumed");
  const feeAtoms = unsigned(simulation, "feeAtoms");
  const deltas = accountDeltas(simulation, accounts);

  if (!accounts.includes(destination)) {
    throw new Error("destination is not a declared account");
  }
  if (
    market !== intent.instrument ||
    BigInt(quantityAtoms) > BigInt(intent.maxQuantityAtoms as string) ||
    BigInt(computeUnitsConsumed) > BigInt(computeUnitLimit) ||
    (intent.side === "BUY" &&
      BigInt(averagePriceAtoms) > BigInt(intent.limitPriceAtoms as string)) ||
    (intent.side === "SELL" &&
      BigInt(averagePriceAtoms) < BigInt(intent.limitPriceAtoms as string))
  ) {
    throw new Error("simulation exceeds execution intent");
  }

  const messageHash = createHash("sha256")
    .update(
      canonicalJson({
        accountDeltas: deltas,
        accounts,
        averagePriceAtoms,
        computeUnitLimit,
        computeUnitsConsumed,
        destination,
        feeAtoms,
        market,
        mint,
        priorityFeeLamports,
        programIds,
        quantityAtoms,
        simulationId: text(simulation, "simulationId"),
      }),
    )
    .digest("hex");

  return {
    schemaVersion: 1,
    commandId: `${intent.intentId as string}:shadow:1`,
    intentHash: executionIntentHash(intent),
    programIds,
    accounts,
    market,
    mint,
    destination,
    quantityAtoms,
    limitPriceAtoms: averagePriceAtoms,
    priorityFeeLamports,
    computeUnitLimit,
    simulateOnly: true,
    submit: false,
    messageHash,
    simulatedQuantityAtoms: quantityAtoms,
    simulatedAveragePriceAtoms: averagePriceAtoms,
    simulatedFeeAtoms: feeAtoms,
    computeUnitsConsumed,
    accountDeltas: deltas,
  };
}
