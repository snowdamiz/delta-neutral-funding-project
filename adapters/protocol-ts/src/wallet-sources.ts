import { createHash } from "node:crypto";
import type { AdapterConfig } from "./config.js";
import {
  type WalletFill,
  type WalletObservationEvent,
  type WalletObservationPayload,
  type WalletPosition,
  validateEvent,
} from "./contracts.js";
import { hyperliquidInfo, l2 } from "./funding-sources.js";

type JsonObject = Record<string, unknown>;

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

function decimal(value: unknown, scale: number, field: string): bigint {
  const raw = typeof value === "string" ? value : String(value);
  const match = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?$/.exec(raw);
  if (!match) throw new Error(`${field} must be a plain decimal`);
  const atoms =
    BigInt(match[2] as string) * 10n ** BigInt(scale) +
    BigInt((match[3] ?? "").slice(0, scale).padEnd(scale, "0") || "0");
  return match[1] === "-" ? -atoms : atoms;
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

function absolute(value: bigint): bigint {
  return value < 0n ? -value : value;
}

function direction(value: string): WalletFill["direction"] {
  const normalized = value.toLowerCase();
  if (normalized.startsWith("open ")) return "open";
  if (normalized.startsWith("close ")) return "close";
  if (normalized.startsWith("increase ")) return "increase";
  if (normalized.startsWith("reduce ")) return "reduce";
  if (normalized.startsWith("flip ")) return "flip";
  if (normalized === "long > short" || normalized === "short > long") return "flip";
  throw new Error(`unsupported Hyperliquid fill direction ${value}`);
}

function position(value: unknown, index: number): WalletPosition {
  const row = object(value, `assetPositions[${index}]`);
  const item = object(row.position, `assetPositions[${index}].position`);
  const asset = text(item.coin, "position coin").toUpperCase();
  const signedQuantity = decimal(item.szi, 9, `${asset} position size`);
  if (signedQuantity === 0n) throw new Error(`${asset} position size must be nonzero`);
  const quantity = absolute(signedQuantity);
  const positionValue = absolute(decimal(item.positionValue, 6, `${asset} position value`));
  const leverage = object(item.leverage, `${asset} leverage`);
  return {
    asset,
    side: signedQuantity > 0n ? "long" : "short",
    quantityAtoms: quantity.toString(),
    entryPriceUsdMicros: absolute(
      decimal(item.entryPx, 6, `${asset} entry price`),
    ).toString(),
    markPriceUsdMicros: (
      positionValue * 1_000_000_000n / quantity
    ).toString(),
    leveragePpm: decimal(leverage.value, 6, `${asset} leverage`).toString(),
    unrealizedPnlUsdMicros: decimal(
      item.unrealizedPnl,
      6,
      `${asset} unrealized PnL`,
    ).toString(),
  };
}

export async function captureWalletObservations(
  config: AdapterConfig,
  wallets: string[],
  sequence: bigint,
  observedAtMs: bigint,
  fillStartAtMs: bigint,
): Promise<WalletObservationEvent[]> {
  if (fillStartAtMs < 0n || fillStartAtMs > observedAtMs) {
    throw new Error("wallet fill window is invalid");
  }
  return Promise.all(wallets.map(async (wallet, walletIndex) => {
    const startedAtMs = Date.now();
    const [stateResponse, fillsResponse] = await Promise.all([
      hyperliquidInfo(config, { type: "clearinghouseState", user: wallet }),
      hyperliquidInfo(config, {
        type: "userFillsByTime",
        user: wallet,
        startTime: Number(fillStartAtMs),
        endTime: Number(observedAtMs),
        aggregateByTime: true,
      }),
    ]);
    const state = object(stateResponse.value, "clearinghouse state");
    const margin = object(state.marginSummary, "margin summary");
    const positions = array(state.assetPositions, "asset positions")
      .map(position);
    const returnedFills = array(fillsResponse.value, "user fills");
    if (returnedFills.length >= 2000) {
      throw new Error("wallet fill response reached the 2000-row limit");
    }
    const rawFills = returnedFills.filter((value, index) =>
      !text(object(value, `fills[${index}]`).coin, "fill coin").startsWith("@")
    );
    const books = new Map<string, Awaited<ReturnType<typeof l2>>>();

    for (const [index, value] of rawFills.entries()) {
      const fill = object(value, `fills[${index}]`);
      const asset = text(fill.coin, "fill coin").toUpperCase();
      const price = decimal(fill.px, 6, `${asset} fill price`);
      if (price <= 0n) throw new Error(`${asset} fill price must be positive`);
      if (!books.has(asset)) {
        const paperQuantity =
          config.paperNotionalUsdMicros * 1_000_000_000n / price;
        if (paperQuantity === 0n) throw new Error(`${asset} paper quantity is zero`);
        books.set(asset, await l2(config, asset, paperQuantity));
      }
    }
    const apiLatencyMs = BigInt(Math.max(0, Date.now() - startedAtMs));
    const capturedAtMs = observedAtMs + apiLatencyMs;

    const fills = rawFills.map((value, index): WalletFill => {
      const fill = object(value, `fills[${index}]`);
      const asset = text(fill.coin, "fill coin").toUpperCase();
      const side = text(fill.side, `${asset} fill side`);
      if (side !== "B" && side !== "A") {
        throw new Error(`${asset} fill side must be B or A`);
      }
      const filledAtMs = unsigned(fill.time, `${asset} fill time`);
      if (filledAtMs > observedAtMs) throw new Error(`${asset} fill is in the future`);
      const book = books.get(asset);
      if (!book) throw new Error(`${asset} copy book is missing`);
      const leaderPrice = decimal(fill.px, 6, `${asset} fill price`);
      const paperQuantity =
        config.paperNotionalUsdMicros * 1_000_000_000n / leaderPrice;
      const buy = side === "B";
      return {
        fillId: `${text(fill.hash, `${asset} fill hash`)}:${unsigned(fill.tid, `${asset} trade id`)}`,
        asset,
        side: buy ? "buy" : "sell",
        direction: direction(text(fill.dir, `${asset} fill direction`)),
        quantityAtoms: decimal(fill.sz, 9, `${asset} fill size`).toString(),
        leaderPriceUsdMicros: leaderPrice.toString(),
        copyBidPriceUsdMicros: book.bid.toString(),
        copyAskPriceUsdMicros: book.ask.toString(),
        closedPnlUsdMicros: decimal(
          fill.closedPnl,
          6,
          `${asset} closed PnL`,
        ).toString(),
        feeUsdMicros: decimal(fill.fee, 6, `${asset} fee`).toString(),
        filledAtMs: filledAtMs.toString(),
        copyObservedAtMs: capturedAtMs.toString(),
        copyLatencyMs: (capturedAtMs - filledAtMs).toString(),
        copyBidDepthQualified: book.bidDepth >= paperQuantity,
        copyAskDepthQualified: book.askDepth >= paperQuantity,
      };
    });
    const payload: WalletObservationPayload = {
      wallet,
      sourceObservedAtMs: observedAtMs.toString(),
      accountValueUsdMicros: decimal(
        margin.accountValue,
        6,
        "account value",
      ).toString(),
      totalNotionalUsdMicros: decimal(
        margin.totalNtlPos,
        6,
        "total notional",
      ).toString(),
      apiLatencyMs: apiLatencyMs.toString(),
      positions,
      fills,
    };
    const raw = `${stateResponse.raw}\n${fillsResponse.raw}\n${[...books.values()]
      .map((book) => book.raw)
      .join("\n")}`;
    const event: WalletObservationEvent = {
      schemaVersion: 1,
      eventId: `${config.sessionId}-wallet-${sequence}-${walletIndex}`,
      eventType: "WalletObservation",
      source: `hyperliquid-wallet:${wallet}`,
      observedAtMs: capturedAtMs.toString(),
      sourceSlot: capturedAtMs.toString(),
      sourceSequence: `${config.sessionId}:wallet-${sequence}`,
      idempotencyKey: `${config.sessionId}:wallet-${sequence}:${wallet}`,
      rawPayloadHash: createHash("sha256").update(raw).digest("hex"),
      payload,
    };
    return validateEvent(event) as WalletObservationEvent;
  }));
}
