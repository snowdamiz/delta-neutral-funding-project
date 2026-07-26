import { createHash } from "node:crypto";
import { type AdapterConfig } from "./config.js";
import {
  type FundingSettlementEvent,
  type MarketSnapshotEvent,
  type MarketSnapshotPayload,
  validateEvent,
} from "./contracts.js";

const stakePoolAddress = "Jito4APyf642JPZPx3hGc6WWJ8zPKtRbRs4P815Awbb";
const stakePoolOwner = "SPoo1Ku8WFXoNDMHPsrGSTSG1Y47rzgn41SLUNakuHy";
const jitoMint = "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn";
const tokenProgram = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const solMint = "So11111111111111111111111111111111111111112";
const usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const million = 1_000_000n;
const billion = 1_000_000_000n;

type ObjectValue = Record<string, unknown>;
type RawJson = { raw: string; value: unknown };
type Rounding = "floor" | "ceil";

type PhoenixCapture = {
  bidPrice: bigint;
  askPrice: bigint;
  depthLamports: bigint;
  feePpm: bigint;
  maintenanceBps: bigint;
  fundingPpm: bigint;
  fundingTimestampSeconds: bigint;
  fundingPriceUsdMicros: bigint;
  slots: bigint[];
  raw: string;
  endpoint: string;
};

type SolanaCapture = {
  totalPoolLamports: bigint;
  supplyAtoms: bigint;
  epoch: bigint;
  slots: bigint[];
  raw: string;
  endpoint: string;
};

type JupiterCapture = {
  solBidPrice: bigint;
  solAskPrice: bigint;
  jitoBidPrice: bigint;
  jitoAskPrice: bigint;
  slots: bigint[];
  raw: string;
  endpoint: string;
};

export type AuthoritativeCapture = {
  snapshot: MarketSnapshotEvent;
  funding: FundingSettlementEvent;
  navLamports: bigint;
  endpoints: { phoenix: string; solana: string; jupiter: string };
};

function object(value: unknown, field: string): ObjectValue {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as ObjectValue;
}

function array(value: unknown, field: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${field} must be an array`);
  return value;
}

function text(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${field} must be a non-empty string`);
  }
  return value;
}

function integer(value: unknown, field: string): bigint {
  if (
    typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value >= 0
  ) {
    return BigInt(value);
  }
  if (typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value)) {
    return BigInt(value);
  }
  throw new Error(`${field} must be an unsigned safe integer`);
}

function decimal(
  value: unknown,
  scale: number,
  rounding: Rounding,
  field: string,
): bigint {
  const raw =
    typeof value === "string"
      ? value
      : typeof value === "number" && Number.isFinite(value)
        ? String(value)
        : "";
  const match = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?$/.exec(raw);
  if (!match) throw new Error(`${field} must be a plain canonical decimal`);
  const negative = match[1] === "-";
  const whole = match[2] as string;
  const fraction = match[3] ?? "";
  const kept = fraction.slice(0, scale).padEnd(scale, "0");
  const discarded = fraction.slice(scale);
  let atoms = BigInt(whole) * 10n ** BigInt(scale) + BigInt(kept || "0");
  if (discarded.includes("1") || /[2-9]/.test(discarded)) {
    if ((!negative && rounding === "ceil") || (negative && rounding === "floor")) {
      atoms += 1n;
    }
  }
  return negative ? -atoms : atoms;
}

function positive(value: bigint, field: string): bigint {
  if (value <= 0n) throw new Error(`${field} must be positive`);
  return value;
}

function ceilDiv(numerator: bigint, denominator: bigint): bigint {
  if (numerator < 0n || denominator <= 0n) {
    throw new Error("ceilDiv requires a non-negative numerator and positive denominator");
  }
  return (numerator + denominator - 1n) / denominator;
}

function hash(raw: string): string {
  return createHash("sha256").update(raw).digest("hex");
}

function join(base: string, suffix: string): string {
  return `${base.replace(/\/+$/, "")}/${suffix.replace(/^\/+/, "")}`;
}

async function fetchJson(
  url: string,
  timeoutMs: number,
  init?: RequestInit,
): Promise<RawJson> {
  const response = await fetch(url, {
    ...init,
    signal: AbortSignal.timeout(timeoutMs),
  });
  const raw = await response.text();
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${raw.slice(0, 200)}`);
  try {
    return { raw, value: JSON.parse(raw) as unknown };
  } catch {
    throw new Error("response was not JSON");
  }
}

async function firstProvider<T>(
  label: string,
  urls: string[],
  load: (url: string) => Promise<T>,
): Promise<T> {
  const errors: string[] = [];
  for (const url of urls) {
    try {
      return await load(url);
    } catch (error) {
      errors.push(`${url}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  throw new Error(`${label} sources failed: ${errors.join("; ")}`);
}

function timestampSeconds(value: unknown, field: string): bigint {
  if (
    (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) ||
    (typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value))
  ) {
    return integer(value, field);
  }
  const raw = text(value, field);
  const parsed = Date.parse(raw);
  if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed % 1000 !== 0) {
    throw new Error(`${field} must be epoch seconds or an exact ISO timestamp`);
  }
  return BigInt(parsed / 1000);
}

function level(value: unknown, side: "bid" | "ask", index: number): [bigint, bigint] {
  const pair = array(value, `${side}[${index}]`);
  if (pair.length !== 2) throw new Error(`${side}[${index}] must contain price and size`);
  return [
    positive(
      decimal(pair[0], 6, side === "bid" ? "floor" : "ceil", `${side} price`),
      `${side} price`,
    ),
    positive(decimal(pair[1], 9, "floor", `${side} size`), `${side} size`),
  ];
}

function book(value: unknown, slippageBps: bigint): {
  bid: bigint;
  ask: bigint;
  depth: bigint;
  slot: bigint;
} {
  const orderbook = object(value, "Phoenix orderbook");
  if (text(orderbook.symbol, "orderbook symbol") !== "SOL") {
    throw new Error("Phoenix orderbook symbol must be SOL");
  }
  const bids = array(orderbook.bids, "orderbook bids").map((item, index) =>
    level(item, "bid", index),
  );
  const asks = array(orderbook.asks, "orderbook asks").map((item, index) =>
    level(item, "ask", index),
  );
  if (bids.length === 0 || asks.length === 0) {
    throw new Error("Phoenix orderbook must have both sides");
  }
  const bid = bids.reduce((best, [price]) => price > best ? price : best, 0n);
  const ask = asks.reduce((best, [price]) => price < best ? price : best, asks[0]![0]);
  if (bid >= ask) throw new Error("Phoenix orderbook is crossed");
  const slippagePpm = slippageBps * 100n;
  const bidDepth = bids
    .filter(([price]) => price * million >= bid * (million - slippagePpm))
    .reduce((sum, [, size]) => sum + size, 0n);
  const askDepth = asks
    .filter(([price]) => price * million <= ask * (million + slippagePpm))
    .reduce((sum, [, size]) => sum + size, 0n);
  return {
    bid,
    ask,
    depth: bidDepth < askDepth ? bidDepth : askDepth,
    slot: integer(orderbook.slot, "orderbook slot"),
  };
}

async function phoenix(config: AdapterConfig): Promise<PhoenixCapture> {
  return firstProvider("Phoenix", config.phoenixUrls, async (endpoint) => {
    const headers: Record<string, string> = {};
    if (config.phoenixBearerToken.length > 0) {
      headers.authorization = `Bearer ${config.phoenixBearerToken}`;
    }
    const [marketResponse, bookResponse, fundingResponse] = await Promise.all([
      fetchJson(
        join(endpoint, "v1/view/exchange/market/SOL"),
        config.requestTimeoutMs,
        { headers },
      ),
      fetchJson(
        join(endpoint, "v1/view/orderbook/SOL"),
        config.requestTimeoutMs,
        { headers },
      ),
      fetchJson(
        join(endpoint, "v1/funding/SOL/rates?limit=1"),
        config.requestTimeoutMs,
        { headers },
      ),
    ]);
    const market = object(marketResponse.value, "Phoenix market");
    if (
      text(market.symbol, "market symbol") !== "SOL" ||
      text(market.marketStatus, "market status") !== "active"
    ) {
      throw new Error("Phoenix SOL market is not active");
    }
    const risk = object(market.riskFactors, "market risk factors");
    const maintenanceBps = integer(risk.maintenanceBps, "maintenanceBps");
    if (maintenanceBps === 0n || maintenanceBps > 10_000n) {
      throw new Error("maintenanceBps must be between 1 and 10000");
    }
    const feePpm = decimal(market.takerFee, 6, "ceil", "takerFee");
    if (feePpm < 0n || feePpm > million) {
      throw new Error("takerFee is outside the supported range");
    }
    const parsedBook = book(bookResponse.value, config.paperSlippageBps);
    if (parsedBook.depth === 0n) throw new Error("Phoenix executable depth is zero");

    const funding = object(fundingResponse.value, "Phoenix funding");
    if (text(funding.symbol, "funding symbol") !== "SOL") {
      throw new Error("Phoenix funding symbol must be SOL");
    }
    const rates = array(funding.rates, "funding rates");
    if (rates.length === 0) throw new Error("Phoenix funding history is empty");
    const latest = rates
      .map((item) => object(item, "funding rate"))
      .reduce((left, right) =>
        timestampSeconds(left.timestamp, "funding timestamp") >=
        timestampSeconds(right.timestamp, "funding timestamp")
          ? left
          : right,
      );
    const fundingTimestamp = timestampSeconds(
      latest.timestamp,
      "funding timestamp",
    );
    if (fundingTimestamp < 3600n) {
      throw new Error("funding timestamp has no preceding hourly candle");
    }
    const fundingAtMs = fundingTimestamp * 1000n;
    const candleAtMs = fundingAtMs - 3_600_000n;
    const candleResponse = await fetchJson(
      join(
        endpoint,
        `candles?symbol=SOL&timeframe=1h&startTime=${candleAtMs}&endTime=${fundingAtMs}`,
      ),
      config.requestTimeoutMs,
      { headers },
    );
    const candle = array(candleResponse.value, "Phoenix candles")
      .map((item) => object(item, "Phoenix candle"))
      .find((item) => integer(item.time, "candle time") === candleAtMs);
    if (!candle) throw new Error("Phoenix funding candle is missing");
    const stats = object(market.statsSnapshot, "market stats");
    return {
      bidPrice: parsedBook.bid,
      askPrice: parsedBook.ask,
      depthLamports: parsedBook.depth,
      feePpm,
      maintenanceBps,
      fundingPpm: decimal(
        latest.fundingRatePercentage,
        4,
        "floor",
        "fundingRatePercentage",
      ),
      fundingTimestampSeconds: fundingTimestamp,
      fundingPriceUsdMicros: positive(
        decimal(candle.markClose, 6, "floor", "funding mark close"),
        "funding mark close",
      ),
      slots: [parsedBook.slot, integer(stats.slot, "market stats slot")],
      raw: [marketResponse.raw, bookResponse.raw, fundingResponse.raw].join("\n"),
      endpoint,
    };
  });
}

function base64(value: unknown, field: string): Buffer {
  const encoded = text(value, field);
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
    throw new Error(`${field} must be canonical base64`);
  }
  return Buffer.from(encoded, "base64");
}

function rpcResult(responses: unknown[], id: number): ObjectValue {
  const response = responses
    .map((item) => object(item, "RPC response"))
    .find((item) => item.id === id);
  if (!response) throw new Error(`RPC response ${id} is missing`);
  if (response.error !== undefined) {
    throw new Error(`RPC response ${id} failed: ${JSON.stringify(response.error)}`);
  }
  return object(response.result, `RPC result ${id}`);
}

async function solana(config: AdapterConfig): Promise<SolanaCapture> {
  return firstProvider("Solana RPC", config.solanaRpcUrls, async (endpoint) => {
    const response = await fetchJson(endpoint, config.requestTimeoutMs, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify([
        {
          jsonrpc: "2.0",
          id: 1,
          method: "getMultipleAccounts",
          params: [
            [stakePoolAddress, jitoMint],
            { commitment: "confirmed", encoding: "base64" },
          ],
        },
        {
          jsonrpc: "2.0",
          id: 2,
          method: "getEpochInfo",
          params: [{ commitment: "confirmed" }],
        },
      ]),
    });
    const responses = array(response.value, "RPC batch");
    const accountsResult = rpcResult(responses, 1);
    const context = object(accountsResult.context, "RPC account context");
    const accounts = array(accountsResult.value, "RPC accounts");
    if (accounts.length !== 2) throw new Error("RPC did not return both Jito accounts");
    const poolAccount = object(accounts[0], "stake pool account");
    const mintAccount = object(accounts[1], "JitoSOL mint account");
    if (text(poolAccount.owner, "stake pool owner") !== stakePoolOwner) {
      throw new Error("unexpected Jito stake pool owner");
    }
    if (text(mintAccount.owner, "mint owner") !== tokenProgram) {
      throw new Error("unexpected JitoSOL mint owner");
    }
    const poolDataField = array(poolAccount.data, "stake pool data");
    const mintDataField = array(mintAccount.data, "mint data");
    if (poolDataField[1] !== "base64" || mintDataField[1] !== "base64") {
      throw new Error("RPC account encoding must be base64");
    }
    const pool = base64(poolDataField[0], "stake pool data");
    const mint = base64(mintDataField[0], "mint data");
    if (pool.length !== 611 || pool[0] !== 1) {
      throw new Error("unexpected Jito stake pool layout");
    }
    if (mint.length !== 82 || mint[44] !== 9 || mint[45] !== 1) {
      throw new Error("unexpected JitoSOL mint layout");
    }
    const totalPoolLamports = pool.readBigUInt64LE(258);
    const supplyAtoms = pool.readBigUInt64LE(266);
    const lastUpdateEpoch = pool.readBigUInt64LE(274);
    const mintSupply = mint.readBigUInt64LE(36);
    positive(totalPoolLamports, "stake pool total lamports");
    positive(supplyAtoms, "stake pool supply");
    if (mintSupply !== supplyAtoms) {
      throw new Error("mint supply does not match stake pool");
    }
    const epochInfo = rpcResult(responses, 2);
    const epoch = integer(epochInfo.epoch, "current epoch");
    if (lastUpdateEpoch !== epoch) {
      throw new Error("Jito stake pool is stale for the current epoch");
    }
    return {
      totalPoolLamports,
      supplyAtoms,
      epoch,
      slots: [
        integer(context.slot, "RPC account slot"),
        integer(epochInfo.absoluteSlot, "epoch absolute slot"),
      ],
      raw: response.raw,
      endpoint,
    };
  });
}

function quoteUrl(
  base: string,
  inputMint: string,
  outputMint: string,
  amount: bigint,
  mode: "ExactIn" | "ExactOut",
  slippageBps: bigint,
): string {
  const url = new URL(join(base, "quote"));
  url.searchParams.set("inputMint", inputMint);
  url.searchParams.set("outputMint", outputMint);
  url.searchParams.set("amount", amount.toString());
  url.searchParams.set("swapMode", mode);
  url.searchParams.set("slippageBps", slippageBps.toString());
  url.searchParams.set("restrictIntermediateTokens", "true");
  return url.toString();
}

function quote(
  value: unknown,
  inputMint: string,
  outputMint: string,
  amount: bigint,
  mode: "ExactIn" | "ExactOut",
  slippageBps: bigint,
): { input: bigint; output: bigint; slot: bigint } {
  const result = object(value, "Jupiter quote");
  if (
    text(result.inputMint, "quote inputMint") !== inputMint ||
    text(result.outputMint, "quote outputMint") !== outputMint ||
    text(result.swapMode, "quote swapMode") !== mode
  ) {
    throw new Error("Jupiter quote identity does not match the request");
  }
  const input = integer(result.inAmount, "quote inAmount");
  const output = integer(result.outAmount, "quote outAmount");
  positive(input, "quote inAmount");
  positive(output, "quote outAmount");
  if ((mode === "ExactIn" ? input : output) !== amount) {
    throw new Error("Jupiter quote amount does not match the request");
  }
  if (integer(result.slippageBps, "quote slippageBps") !== slippageBps) {
    throw new Error("Jupiter quote slippage does not match the request");
  }
  if (array(result.routePlan, "quote routePlan").length === 0) {
    throw new Error("Jupiter quote route is empty");
  }
  return { input, output, slot: integer(result.contextSlot, "quote contextSlot") };
}

async function jupiter(
  config: AdapterConfig,
  solQuantityAtoms: bigint,
): Promise<JupiterCapture> {
  return firstProvider("Jupiter", config.jupiterUrls, async (endpoint) => {
    const request =
      config.jupiterApiKey.length > 0
        ? { headers: { "x-api-key": config.jupiterApiKey } }
        : {};
    const specs = [
      [solMint, usdcMint, solQuantityAtoms, "ExactIn"],
      [usdcMint, solMint, solQuantityAtoms, "ExactOut"],
      [jitoMint, usdcMint, config.paperQuantityAtoms, "ExactIn"],
      [usdcMint, jitoMint, config.paperQuantityAtoms, "ExactOut"],
    ] as const;
    const responses = await Promise.all(specs.map(([input, output, amount, mode]) =>
      fetchJson(
        quoteUrl(endpoint, input, output, amount, mode, config.paperSlippageBps),
        config.requestTimeoutMs,
        request,
      ),
    ));
    const quotes = responses.map((response, index) => {
      const spec = specs[index]!;
      return quote(
        response.value,
        spec[0],
        spec[1],
        spec[2],
        spec[3],
        config.paperSlippageBps,
      );
    });
    const [solBid, solAsk, jitoBid, jitoAsk] = quotes as [
      { input: bigint; output: bigint; slot: bigint },
      { input: bigint; output: bigint; slot: bigint },
      { input: bigint; output: bigint; slot: bigint },
      { input: bigint; output: bigint; slot: bigint },
    ];
    return {
      solBidPrice: solBid.output * billion / solBid.input,
      solAskPrice: ceilDiv(solAsk.input * billion, solAsk.output),
      jitoBidPrice: jitoBid.output * billion / jitoBid.input,
      jitoAskPrice: ceilDiv(jitoAsk.input * billion, jitoAsk.output),
      slots: quotes.map(({ slot }) => slot),
      raw: responses.map(({ raw }) => raw).join("\n"),
      endpoint,
    };
  });
}

function coherentSlots(slots: bigint[], maxDrift: bigint): bigint {
  const lowest = slots.reduce((left, right) => left < right ? left : right);
  const highest = slots.reduce((left, right) => left > right ? left : right);
  if (highest - lowest > maxDrift) {
    throw new Error(`source slot drift ${highest - lowest} exceeds ${maxDrift}`);
  }
  return highest;
}

export async function buildAuthoritativeEvents(
  config: AdapterConfig,
  sequence: bigint,
  observedAtMs: bigint,
  previousNavLamports?: bigint,
): Promise<AuthoritativeCapture> {
  if (config.mode !== "authoritative") {
    throw new Error("authoritative source capture requires authoritative mode");
  }
  const [perp, pool] = await Promise.all([
    phoenix(config),
    solana(config),
  ]);
  const navLamports = pool.totalPoolLamports * billion / pool.supplyAtoms;
  const solQuoteAtoms = ceilDiv(
    config.paperQuantityAtoms * navLamports,
    billion,
  );
  const spot = await jupiter(config, solQuoteAtoms);
  const sourceSlot = coherentSlots(
    [...perp.slots, ...pool.slots, ...spot.slots],
    config.sourceMaxSlotDrift,
  );
  const fundingAtMs = perp.fundingTimestampSeconds * 1000n;
  if (
    fundingAtMs > observedAtMs ||
    observedAtMs - fundingAtMs > config.sourceMaxFundingAgeMs
  ) {
    throw new Error("Phoenix funding record is stale or in the future");
  }
  if (perp.fundingPpm < -million || perp.fundingPpm > million) {
    throw new Error("Phoenix funding rate is outside the supported range");
  }
  const hedgeLamports =
    config.paperQuantityAtoms * spot.jitoBidPrice / spot.solBidPrice;
  const notionalUsdMicros = hedgeLamports * spot.solBidPrice / billion;
  if (notionalUsdMicros > config.paperNotionalUsdMicros) {
    throw new Error("paper notional exceeds its configured cap");
  }
  const maintenance = ceilDiv(
    notionalUsdMicros * perp.maintenanceBps,
    10_000n,
  );
  const liquidationDistance =
    config.paperCollateralUsdMicros <= maintenance
      ? 0n
      : (config.paperCollateralUsdMicros - maintenance) * 10_000n /
        config.paperCollateralUsdMicros;
  const payload: MarketSnapshotPayload = {
    epoch: pool.epoch.toString(),
    oracleStatus: "valid",
    totalPoolLamports: pool.totalPoolLamports.toString(),
    supplyAtoms: pool.supplyAtoms.toString(),
    jitosolAtoms: config.paperQuantityAtoms.toString(),
    notionalUsdMicros: notionalUsdMicros.toString(),
    shortReceiptPpm: perp.fundingPpm.toString(),
    solPriceUsdMicros: spot.solBidPrice.toString(),
    priorNavLamports: (previousNavLamports ?? navLamports).toString(),
    costsUsdMicros: config.paperCostsUsdMicros.toString(),
    riskHaircutUsdMicros: config.paperRiskHaircutUsdMicros.toString(),
    collateralUsdMicros: config.paperCollateralUsdMicros.toString(),
    maintenanceRequirementUsdMicros: maintenance.toString(),
    liquidationDistanceBps: liquidationDistance.toString(),
    solSpotBidPriceUsdMicros: spot.solBidPrice.toString(),
    solSpotAskPriceUsdMicros: spot.solAskPrice.toString(),
    jitosolSpotBidPriceUsdMicros: spot.jitoBidPrice.toString(),
    jitosolSpotAskPriceUsdMicros: spot.jitoAskPrice.toString(),
    perpBidPriceUsdMicros: perp.bidPrice.toString(),
    perpAskPriceUsdMicros: perp.askPrice.toString(),
    solExitDepthLamports: solQuoteAtoms.toString(),
    jitosolExitDepthLamports: hedgeLamports.toString(),
    perpExitDepthLamports: perp.depthLamports.toString(),
    fillRatePpm: "1000000",
    slippagePpm: (config.paperSlippageBps * 100n).toString(),
    spotFeePpm: "0",
    perpFeePpm: perp.feePpm.toString(),
    rejectRatePpm: "0",
    unknownRatePpm: "0",
  };
  const source = `authoritative:${config.sessionId}`;
  const sourceRaw = [
    `phoenix:${perp.raw}`,
    `solana:${pool.raw}`,
    `jupiter:${spot.raw}`,
  ].join("\n");
  const snapshot = validateEvent({
    schemaVersion: 1,
    eventId: `authoritative-${config.sessionId}-${sequence}`,
    eventType: "MarketSnapshot",
    source,
    observedAtMs: observedAtMs.toString(),
    sourceSlot: sourceSlot.toString(),
    sourceSequence: sequence.toString(),
    idempotencyKey: `${source}:${sequence}`,
    rawPayloadHash: hash(sourceRaw),
    payload,
  }) as MarketSnapshotEvent;
  const fundingIdentity = `phoenix:SOL:${perp.fundingTimestampSeconds}`;
  const fundingHash = hash([
    fundingIdentity,
    perp.fundingPpm,
    perp.fundingPriceUsdMicros,
  ].join(":"));
  const funding = validateEvent({
    schemaVersion: 1,
    eventId: `phoenix-SOL-funding-${perp.fundingTimestampSeconds}`,
    eventType: "FundingSettlement",
    source: "phoenix-funding:SOL",
    observedAtMs: fundingAtMs.toString(),
    sourceSlot: perp.fundingTimestampSeconds.toString(),
    sourceSequence: `funding-${perp.fundingTimestampSeconds}`,
    idempotencyKey: fundingIdentity,
    rawPayloadHash: fundingHash,
    payload: {
      venuePaymentId: fundingIdentity,
      effectiveAtMs: fundingAtMs.toString(),
      realizedShortRatePpm: perp.fundingPpm.toString(),
      solPriceUsdMicros: perp.fundingPriceUsdMicros.toString(),
    },
  }) as FundingSettlementEvent;
  return {
    snapshot,
    funding,
    navLamports,
    endpoints: {
      phoenix: perp.endpoint,
      solana: pool.endpoint,
      jupiter: spot.endpoint,
    },
  };
}
