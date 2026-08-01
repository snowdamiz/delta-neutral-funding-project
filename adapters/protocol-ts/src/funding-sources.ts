import { createHash } from "node:crypto";
import { type AdapterConfig } from "./config.js";
import {
  type FundingObservationEvent,
  type FundingObservationPayload,
  validateEvent,
} from "./contracts.js";

type JsonObject = Record<string, unknown>;
type BorrowFields = Pick<
  FundingObservationPayload,
  | "borrowVenue"
  | "borrowMarket"
  | "borrowReserve"
  | "borrowMint"
  | "borrowSourceObservedAtMs"
  | "borrowSourceStatus"
  | "borrowRatePpmPerHour"
  | "borrowAvailableUsdMicros"
  | "borrowUtilizationPpm"
>;
export type FundingObservationRow = Omit<
  FundingObservationPayload,
  "scanId" | "scanIndex" | "scanSize" | keyof BorrowFields
> & {
  raw: string;
};
type BorrowSnapshot = BorrowFields & { raw: string };

const million = 1_000_000n;
const billion = 1_000_000_000n;

function object(value: unknown, field: string): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as JsonObject;
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

function unsigned(value: unknown, field: string): bigint {
  if (
    (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) ||
    (typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value))
  ) {
    return BigInt(value);
  }
  throw new Error(`${field} must be an unsigned integer`);
}

/** Exact decimal conversion with truncation toward zero. */
function decimal(value: unknown, scale: number, field: string): bigint {
  const raw = typeof value === "string" ? value : String(value);
  const match = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?$/.exec(raw);
  if (!match) throw new Error(`${field} must be a plain decimal`);
  const atoms =
    BigInt(match[2] as string) * 10n ** BigInt(scale) +
    BigInt((match[3] ?? "").slice(0, scale).padEnd(scale, "0") || "0");
  return match[1] === "-" ? -atoms : atoms;
}

function positive(value: bigint, field: string): bigint {
  if (value <= 0n) throw new Error(`${field} must be positive`);
  return value;
}

function ceilDiv(numerator: bigint, denominator: bigint): bigint {
  if (numerator < 0n || denominator <= 0n) {
    throw new Error("ceilDiv requires non-negative numerator and positive denominator");
  }
  return (numerator + denominator - 1n) / denominator;
}

function endpoint(base: string, path: string): string {
  return `${base.replace(/\/+$/, "")}/${path.replace(/^\/+/, "")}`;
}

async function fetchJson(
  url: string,
  timeoutMs: number,
  init?: RequestInit,
): Promise<{ raw: string; value: unknown }> {
  const response = await fetch(url, {
    ...init,
    signal: AbortSignal.timeout(timeoutMs),
  });
  const raw = await response.text();
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${raw.slice(0, 160)}`);
  try {
    return { raw, value: JSON.parse(raw) as unknown };
  } catch {
    throw new Error("response was not JSON");
  }
}

async function first<T>(
  label: string,
  urls: string[],
  load: (url: string) => Promise<T>,
): Promise<T> {
  const errors: string[] = [];
  for (const url of urls) {
    try {
      return await load(url);
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
  }
  throw new Error(`${label} sources failed: ${errors.join("; ")}`);
}

export async function hyperliquidInfo(
  config: AdapterConfig,
  body: JsonObject,
): Promise<{ raw: string; value: unknown }> {
  return first("Hyperliquid", config.hyperliquidUrls, (url) =>
    fetchJson(endpoint(url, "info"), config.requestTimeoutMs, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }));
}

function unavailableBorrow(): BorrowSnapshot {
  return {
    borrowVenue: "none",
    borrowMarket: "none",
    borrowReserve: "none",
    borrowMint: "none",
    borrowSourceObservedAtMs: "0",
    borrowSourceStatus: "unavailable",
    borrowRatePpmPerHour: "0",
    borrowAvailableUsdMicros: "0",
    borrowUtilizationPpm: "0",
    raw: "",
  };
}

function invalidBorrow(
  config: AdapterConfig,
  reserve: AdapterConfig["kaminoBorrowReserves"][number],
  raw: string,
): BorrowSnapshot {
  return {
    borrowVenue: "kamino",
    borrowMarket: config.kaminoLendingMarket,
    borrowReserve: reserve.reserve,
    borrowMint: reserve.mint,
    borrowSourceObservedAtMs: "0",
    borrowSourceStatus: "invalid",
    borrowRatePpmPerHour: "0",
    borrowAvailableUsdMicros: "0",
    borrowUtilizationPpm: "0",
    raw,
  };
}

async function kaminoBorrowSnapshots(
  config: AdapterConfig,
  observedAtMs: bigint,
): Promise<Map<string, BorrowSnapshot>> {
  let response: { raw: string; value: unknown };
  try {
    response = await first("Kamino", config.kaminoUrls, (url) =>
      fetchJson(
        endpoint(
          url,
          `kamino-market/${config.kaminoLendingMarket}/reserves/metrics`,
        ),
        config.requestTimeoutMs,
      ));
  } catch (error) {
    const raw = error instanceof Error ? error.message : String(error);
    return new Map(config.kaminoBorrowReserves.map((reserve) => [
      reserve.asset,
      invalidBorrow(config, reserve, raw),
    ]));
  }

  const rows = array(response.value, "Kamino reserve metrics");
  return new Map(config.kaminoBorrowReserves.map((configured) => {
    try {
      const matches = rows
        .map((value, index) => object(value, `Kamino reserve ${index}`))
        .filter((row) => row.reserve === configured.reserve);
      if (matches.length !== 1) throw new Error("configured reserve was not unique");
      const row = matches[0]!;
      if (
        text(row.liquidityToken, "Kamino liquidity token") !== configured.asset ||
        text(row.liquidityTokenMint, "Kamino liquidity mint") !== configured.mint
      ) {
        throw new Error("configured reserve identity changed");
      }
      const supply = decimal(row.totalSupplyUsd, 6, "Kamino total supply USD");
      const borrowed = decimal(row.totalBorrowUsd, 6, "Kamino total borrow USD");
      const apy = decimal(row.borrowApy, 12, "Kamino borrow APY");
      if (supply <= 0n || borrowed < 0n || borrowed > supply || apy < 0n) {
        throw new Error("Kamino reserve metrics are out of range");
      }
      const hourlyRate = ceilDiv(apy * million, 10n ** 12n * 8_760n);
      const utilization = ceilDiv(borrowed * million, supply);
      if (hourlyRate > million || utilization > million) {
        throw new Error("Kamino reserve rates are out of range");
      }
      return [configured.asset, {
        borrowVenue: "kamino",
        borrowMarket: config.kaminoLendingMarket,
        borrowReserve: configured.reserve,
        borrowMint: configured.mint,
        borrowSourceObservedAtMs: observedAtMs.toString(),
        borrowSourceStatus: "valid",
        borrowRatePpmPerHour: hourlyRate.toString(),
        borrowAvailableUsdMicros: (supply - borrowed).toString(),
        borrowUtilizationPpm: utilization.toString(),
        raw: response.raw,
      } satisfies BorrowSnapshot] as const;
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      return [
        configured.asset,
        invalidBorrow(config, configured, `${response.raw}\n${reason}`),
      ] as const;
    }
  }));
}

export type Book = {
  bid: bigint;
  ask: bigint;
  bidDepth: bigint;
  askDepth: bigint;
  raw: string;
};

function executablePrice(
  levels: [bigint, bigint][],
  quantity: bigint,
  buy: boolean,
): bigint {
  let remaining = quantity;
  let quote = 0n;
  for (const [price, size] of levels) {
    const filled = size < remaining ? size : remaining;
    quote += price * filled;
    remaining -= filled;
    if (remaining === 0n) break;
  }
  if (remaining > 0n) return levels[0]![0];
  return buy ? ceilDiv(quote, quantity) : quote / quantity;
}

function parseBook(
  value: unknown,
  raw: string,
  slippageBps: bigint,
  paperQuantity: bigint,
): Book {
  const book = object(value, "l2 book");
  const sides = array(book.levels, "l2 levels");
  if (sides.length !== 2) throw new Error("l2 levels must contain bids and asks");
  const parseSide = (value: unknown, field: string): [bigint, bigint][] =>
    array(value, field).map((entry, index) => {
      const level = object(entry, `${field}[${index}]`);
      return [
        positive(decimal(level.px, 6, `${field} price`), `${field} price`),
        positive(decimal(level.sz, 9, `${field} size`), `${field} size`),
      ];
    });
  const bids = parseSide(sides[0], "bids")
    .sort((left, right) => left[0] > right[0] ? -1 : left[0] < right[0] ? 1 : 0);
  const asks = parseSide(sides[1], "asks")
    .sort((left, right) => left[0] < right[0] ? -1 : left[0] > right[0] ? 1 : 0);
  if (bids.length === 0 || asks.length === 0) throw new Error("l2 book is empty");
  const bid = bids.reduce((best, [price]) => price > best ? price : best, 0n);
  const ask = asks.reduce(
    (best, [price]) => price < best ? price : best,
    asks[0]![0],
  );
  if (bid >= ask) throw new Error("l2 book is crossed");
  const slippagePpm = slippageBps * 100n;
  return {
    bid: executablePrice(bids, paperQuantity, false),
    ask: executablePrice(asks, paperQuantity, true),
    bidDepth: bids
      .filter(([price]) => price * million >= bid * (million - slippagePpm))
      .reduce((sum, [, size]) => sum + size, 0n),
    askDepth: asks
      .filter(([price]) => price * million <= ask * (million + slippagePpm))
      .reduce((sum, [, size]) => sum + size, 0n),
    raw,
  };
}

export async function l2(
  config: AdapterConfig,
  coin: string,
  paperQuantity: bigint,
): Promise<Book> {
  const response = await hyperliquidInfo(config, { type: "l2Book", coin });
  return parseBook(
    response.value,
    response.raw,
    config.paperSlippageBps,
    paperQuantity,
  );
}

async function hyperliquidFundingHistory(
  config: AdapterConfig,
  coin: string,
  observedAtMs: bigint,
): Promise<{
  latest: { rate: bigint; atMs: bigint } | undefined;
  samples: { observedAtMs: string; ratePpm: string }[];
  raw: string;
}> {
  const response = await hyperliquidInfo(config, {
    type: "fundingHistory",
    coin,
    startTime: Number(observedAtMs - 608_400_000n),
  });
  const rows = array(response.value, `${coin} funding history`)
    .map((value, index) => {
      const record = object(value, `${coin} funding history ${index}`);
      return {
        rate: decimal(record.fundingRate, 6, `${coin} realized funding`),
        atMs: unsigned(record.time, `${coin} realized funding time`),
      };
    })
    .filter(({ atMs }) => atMs <= observedAtMs)
    .sort((left, right) => left.atMs < right.atMs ? -1 : left.atMs > right.atMs ? 1 : 0);
  return {
    latest: rows.at(-1),
    samples: rows.map(({ atMs, rate }) => ({
      observedAtMs: atMs.toString(),
      ratePpm: rate.toString(),
    })),
    raw: response.raw,
  };
}

async function hyperliquidRows(
  config: AdapterConfig,
  observedAtMs: bigint,
  crossVenueAssets: Set<string>,
): Promise<FundingObservationRow[]> {
  const [perpsResponse, spotsResponse] = await Promise.all([
    hyperliquidInfo(config, { type: "metaAndAssetCtxs" }),
    hyperliquidInfo(config, { type: "spotMetaAndAssetCtxs" }),
  ]);
  const perps = array(perpsResponse.value, "perp response");
  const spots = array(spotsResponse.value, "spot response");
  if (perps.length !== 2 || spots.length !== 2) {
    throw new Error("Hyperliquid metadata response must contain metadata and contexts");
  }
  const perpMeta = object(perps[0], "perp metadata");
  const perpUniverse = array(perpMeta.universe, "perp universe");
  const perpContexts = array(perps[1], "perp contexts");
  if (perpUniverse.length !== perpContexts.length) {
    throw new Error("Hyperliquid perp metadata and contexts differ in length");
  }

  const spotMeta = object(spots[0], "spot metadata");
  const tokens = new Map(
    array(spotMeta.tokens, "spot tokens").map((value, index) => {
      const token = object(value, `spot token ${index}`);
      return [Number(unsigned(token.index, "spot token index")), text(token.name, "spot token name")];
    }),
  );
  const spotByAsset = new Map<string, string>();
  for (const [index, value] of array(spotMeta.universe, "spot universe").entries()) {
    const market = object(value, `spot market ${index}`);
    const pair = array(market.tokens, `spot market ${index} tokens`);
    if (pair.length !== 2) continue;
    const base = tokens.get(Number(unsigned(pair[0], "spot base token")));
    const quote = tokens.get(Number(unsigned(pair[1], "spot quote token")));
    if (base && quote === "USDC") {
      spotByAsset.set(base, text(market.name, "spot market name"));
    }
  }

  return Promise.all(perpUniverse.map(async (value, index): Promise<FundingObservationRow> => {
    const market = object(value, `perp market ${index}`);
    const context = object(perpContexts[index], `perp context ${index}`);
    const venueAsset = text(market.name, "perp asset");
    if (!/^[A-Za-z0-9]{1,24}$/.test(venueAsset)) {
      throw new Error(`unsupported Hyperliquid asset identifier ${venueAsset}`);
    }
    const asset = venueAsset.toUpperCase();
    const maxLeverage = positive(
      unsigned(market.maxLeverage, `${asset} max leverage`),
      `${asset} max leverage`,
    );
    if (maxLeverage > 100n) {
      throw new Error(`${asset} max leverage is out of range`);
    }
    const mark = positive(
      decimal(context.markPx, 6, `${asset} mark price`),
      `${asset} mark price`,
    );
    const impact = context.impactPxs === null
      ? []
      : array(context.impactPxs, `${asset} impact prices`);
    let perpBid = impact.length === 2
      ? positive(decimal(impact[0], 6, `${asset} impact bid`), `${asset} impact bid`)
      : mark;
    let perpAsk = impact.length === 2
      ? positive(decimal(impact[1], 6, `${asset} impact ask`), `${asset} impact ask`)
      : mark;
    const openInterestAtoms = decimal(
      context.openInterest,
      9,
      `${asset} open interest`,
    );
    const fundingRate = decimal(context.funding, 6, `${asset} funding`);
    const spotCoin = spotByAsset.get(venueAsset);
    let spotBid = 0n;
    let spotAsk = 0n;
    let spotDepth = 0n;
    let perpDepth = 0n;
    let depthQualified = false;
    let depthRaw = "";
    let realizedFundingRate = 0n;
    let realizedFundingAtMs = 0n;
    let fundingHistory = [{
      observedAtMs: observedAtMs.toString(),
      ratePpm: fundingRate.toString(),
    }];
    if (spotCoin || crossVenueAssets.has(asset)) {
      try {
        const paperQuantity = ceilDiv(
          config.paperNotionalUsdMicros * billion,
          mark,
        );
        const [perpBook, spotBook] = await Promise.all([
          l2(config, venueAsset, paperQuantity),
          spotCoin ? l2(config, spotCoin, paperQuantity) : undefined,
        ]);
        perpBid = perpBook.bid;
        perpAsk = perpBook.ask;
        perpDepth = perpBook.bidDepth < perpBook.askDepth
          ? perpBook.bidDepth
          : perpBook.askDepth;
        const required = paperQuantity * 2n;
        if (spotBook) {
          spotBid = spotBook.bid;
          spotAsk = spotBook.ask;
          spotDepth = spotBook.bidDepth;
          depthQualified =
            spotBook.bidDepth >= required &&
            spotBook.askDepth >= required &&
            perpBook.bidDepth >= required &&
            perpBook.askDepth >= required;
        }
        const history = await hyperliquidFundingHistory(
          config,
          venueAsset,
          observedAtMs,
        );
        if (history.latest) {
          realizedFundingRate = history.latest.rate;
          realizedFundingAtMs = history.latest.atMs;
        }
        if (history.samples.length > 0) fundingHistory = history.samples;
        depthRaw = [perpBook.raw, spotBook?.raw, history.raw]
          .filter(Boolean)
          .join("\n");
      } catch (error) {
        depthRaw = error instanceof Error ? error.message : String(error);
      }
    }
    return {
      venue: "hyperliquid",
      asset,
      instrument: `${asset}-PERP`,
      sourceObservedAtMs: "0",
      sourceStatus: "valid",
      fundingRatePpmPerHour: fundingRate.toString(),
      fundingHistory,
      realizedFundingRatePpm: realizedFundingRate.toString(),
      realizedFundingAtMs: realizedFundingAtMs.toString(),
      markPriceUsdMicros: mark.toString(),
      openInterestUsdMicros: (
        openInterestAtoms * mark / billion
      ).toString(),
      spotBidPriceUsdMicros: spotBid.toString(),
      spotAskPriceUsdMicros: spotAsk.toString(),
      perpBidPriceUsdMicros: perpBid.toString(),
      perpAskPriceUsdMicros: perpAsk.toString(),
      spotExitDepthAtoms: spotDepth.toString(),
      perpExitDepthAtoms: perpDepth.toString(),
      depthQualified,
      marginStatus: "valid",
      maintenanceMarginPpm: ceilDiv(
        million,
        maxLeverage * 2n,
      ).toString(),
      raw: `${perpsResponse.raw}\n${spotsResponse.raw}\n${depthRaw}`,
    };
  }));
}

export async function captureFundingObservations(
  config: AdapterConfig,
  sequence: bigint,
  observedAtMs: bigint,
  additionalRows: FundingObservationRow[] = [],
): Promise<FundingObservationEvent[]> {
  const [rows, borrows] = await Promise.all([
    hyperliquidRows(
      config,
      observedAtMs,
      new Set(additionalRows.map(({ asset }) => asset)),
    ),
    kaminoBorrowSnapshots(config, observedAtMs),
  ]);
  rows.push(...additionalRows);
  const scanId = `funding-${config.sessionId}-${sequence}`;
  return rows.map((row, index) => {
    const sourceObservedAtMs =
      row.sourceObservedAtMs === "0" && row.sourceStatus === "valid"
        ? observedAtMs.toString()
        : row.sourceObservedAtMs;
    const borrow = borrows.get(row.asset) ?? unavailableBorrow();
    const { raw: borrowRaw, ...borrowFields } = borrow;
    const payload: FundingObservationPayload & { raw?: string } = {
      ...row,
      ...borrowFields,
      sourceObservedAtMs,
      scanId,
      scanIndex: String(index),
      scanSize: String(rows.length),
    };
    const { raw: _raw, ...canonicalPayload } = payload as FundingObservationPayload & {
      raw?: string;
    };
    const source = `${row.venue}-funding-observation:${row.asset}`;
    return validateEvent({
      schemaVersion: 1,
      eventId: `${scanId}:${row.venue}:${row.asset}`,
      eventType: "FundingObservation",
      source,
      observedAtMs: observedAtMs.toString(),
      sourceSlot: observedAtMs.toString(),
      sourceSequence: `${config.sessionId}:scan-${sequence}`,
      idempotencyKey: `${source}:${scanId}`,
      rawPayloadHash: createHash("sha256")
        .update(`${row.raw}\n${borrowRaw}`)
        .digest("hex"),
      payload: canonicalPayload,
    }) as FundingObservationEvent;
  });
}
