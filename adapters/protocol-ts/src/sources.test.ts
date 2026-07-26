import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { test } from "node:test";
import { loadConfig } from "./config.js";
import { buildAuthoritativeEvents } from "./sources.js";

const solMint = "So11111111111111111111111111111111111111112";
const jitoMint = "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn";
const usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

function json(response: ServerResponse, value: unknown, status = 200): void {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(value));
}

async function requestBody(request: IncomingMessage): Promise<string> {
  let body = "";
  for await (const chunk of request) body += chunk;
  return body;
}

async function listen(
  handler: (request: IncomingMessage, response: ServerResponse) => void,
): Promise<{ url: string; close: () => Promise<void> }> {
  const server = createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert(address && typeof address !== "string");
  return {
    url: `http://127.0.0.1:${address.port}`,
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

test("normalizes a slotted source bundle, fails over, and rejects corrupt pool state", async () => {
  let primaryRequests = 0;
  let mismatchMintSupply = false;
  const primary = await listen((_request, response) => {
    primaryRequests += 1;
    json(response, { error: "primary unavailable" }, 503);
  });
  const backup = await listen((request, response) => {
    void (async () => {
      const url = new URL(request.url ?? "/", "http://upstream");
      if (url.pathname === "/phoenix/v1/view/exchange/market/SOL") {
        json(response, {
          symbol: "SOL",
          marketStatus: "active",
          takerFee: 0.0004,
          riskFactors: { maintenanceBps: 5000 },
          statsSnapshot: { slot: 320000004 },
        });
        return;
      }
      if (url.pathname === "/phoenix/v1/view/orderbook/SOL") {
        json(response, {
          slot: 320000005,
          symbol: "SOL",
          bids: [[149.98, 100], [149.9, 50]],
          asks: [[150.02, 80], [150.2, 50]],
        });
        return;
      }
      if (url.pathname === "/phoenix/v1/funding/SOL/rates") {
        json(response, {
          marketId: 1,
          symbol: "SOL",
          rates: [{ timestamp: 1785020400, fundingRatePercentage: "0.025000" }],
        });
        return;
      }
      if (url.pathname === "/rpc") {
        const pool = Buffer.alloc(611);
        pool[0] = 1;
        pool.writeBigUInt64LE(12_345_678_900n, 258);
        pool.writeBigUInt64LE(10_000_000_000n, 266);
        pool.writeBigUInt64LE(777n, 274);
        const mint = Buffer.alloc(82);
        mint.writeBigUInt64LE(
          mismatchMintSupply ? 9_999_999_999n : 10_000_000_000n,
          36,
        );
        mint[44] = 9;
        mint[45] = 1;
        const rpc = JSON.parse(await requestBody(request)) as Array<{ id: number }>;
        json(response, rpc.map(({ id }) =>
          id === 1
            ? {
                jsonrpc: "2.0",
                id,
                result: {
                  context: { slot: 320000006 },
                  value: [
                    {
                      data: [pool.toString("base64"), "base64"],
                      executable: false,
                      lamports: 1,
                      owner: "SPoo1Ku8WFXoNDMHPsrGSTSG1Y47rzgn41SLUNakuHy",
                      rentEpoch: 1,
                    },
                    {
                      data: [mint.toString("base64"), "base64"],
                      executable: false,
                      lamports: 1,
                      owner: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
                      rentEpoch: 1,
                    },
                  ],
                },
              }
            : {
                jsonrpc: "2.0",
                id,
                result: {
                  absoluteSlot: 320000006,
                  blockHeight: 1,
                  epoch: 777,
                  slotIndex: 1,
                  slotsInEpoch: 432000,
                  transactionCount: 1,
                },
              },
        ));
        return;
      }
      if (url.pathname === "/jupiter/quote") {
        assert.equal(request.headers["x-api-key"], "test-jupiter-key");
        const input = url.searchParams.get("inputMint");
        const output = url.searchParams.get("outputMint");
        const swapMode = url.searchParams.get("swapMode");
        const quote =
          input === solMint && output === usdcMint
            ? ["2000000000", "299900000", "ExactIn"]
            : input === usdcMint && output === solMint
              ? ["300100000", "2000000000", "ExactOut"]
              : input === jitoMint && output === usdcMint
                ? ["2000000000", "370100000", "ExactIn"]
                : input === usdcMint && output === jitoMint
                  ? ["370500000", "2000000000", "ExactOut"]
                  : null;
        assert(quote);
        assert.equal(swapMode, quote[2]);
        json(response, {
          inputMint: input,
          inAmount: quote[0],
          outputMint: output,
          outAmount: quote[1],
          otherAmountThreshold: quote[1],
          swapMode,
          slippageBps: 5,
          priceImpactPct: "0.0001",
          routePlan: [{ percent: 100, swapInfo: { label: "mock" } }],
          contextSlot: 320000005,
        });
        return;
      }
      json(response, { error: `unexpected ${url.pathname}` }, 404);
    })().catch((error: unknown) => {
      json(response, { error: error instanceof Error ? error.message : String(error) }, 500);
    });
  });

  try {
    const config = loadConfig({
      ADAPTER_HMAC_SECRET: "secret",
      ADAPTER_MODE: "authoritative",
      ADAPTER_SESSION_ID: "source-test",
      PHOENIX_URLS: `${primary.url}/phoenix,${backup.url}/phoenix`,
      SOLANA_RPC_URLS: `${primary.url}/rpc,${backup.url}/rpc`,
      JUPITER_URLS: `${primary.url}/jupiter,${backup.url}/jupiter`,
      JUPITER_API_KEY: "test-jupiter-key",
      SOURCE_MAX_SLOT_DRIFT: "10",
      SOURCE_MAX_FUNDING_AGE_MS: "7200000",
      PAPER_QUANTITY_ATOMS: "2000000000",
      PAPER_NOTIONAL_USD_MICROS: "500000000",
      PAPER_COLLATERAL_USD_MICROS: "500000000",
      PAPER_COSTS_USD_MICROS: "200000",
      PAPER_RISK_HAIRCUT_USD_MICROS: "50000",
      PAPER_SLIPPAGE_BPS: "5",
    });
    const captured = await buildAuthoritativeEvents(
      config,
      7n,
      1_785_024_000_000n,
      1_234_000_000n,
    );

    assert.equal(captured.snapshot.source, "authoritative:source-test");
    assert.equal(captured.snapshot.sourceSlot, "320000006");
    assert.equal(captured.snapshot.payload.totalPoolLamports, "12345678900");
    assert.equal(captured.snapshot.payload.supplyAtoms, "10000000000");
    assert.equal(captured.snapshot.payload.priorNavLamports, "1234000000");
    assert.equal(captured.snapshot.payload.shortReceiptPpm, "250");
    assert.equal(captured.snapshot.payload.solSpotBidPriceUsdMicros, "149950000");
    assert.equal(captured.snapshot.payload.solSpotAskPriceUsdMicros, "150050000");
    assert.equal(captured.snapshot.payload.jitosolSpotBidPriceUsdMicros, "185050000");
    assert.equal(captured.snapshot.payload.jitosolSpotAskPriceUsdMicros, "185250000");
    assert.equal(captured.snapshot.payload.perpBidPriceUsdMicros, "149980000");
    assert.equal(captured.snapshot.payload.perpAskPriceUsdMicros, "150020000");
    assert.equal(captured.snapshot.payload.perpExitDepthLamports, "80000000000");
    assert.equal(captured.snapshot.payload.jitosolExitDepthLamports, "2469135780");
    assert.equal(captured.snapshot.payload.perpFeePpm, "400");
    assert.equal(captured.snapshot.payload.maintenanceRequirementUsdMicros, "250000000");
    assert.equal(captured.snapshot.payload.liquidationDistanceBps, "5000");
    assert.equal(captured.navLamports, 1_234_567_890n);
    assert.equal(captured.funding.payload.venuePaymentId, "phoenix:SOL:1785020400");
    assert.equal(captured.funding.payload.realizedShortRatePpm, "250");
    assert.match(captured.snapshot.rawPayloadHash, /^[0-9a-f]{64}$/);
    assert(primaryRequests >= 3);

    mismatchMintSupply = true;
    await assert.rejects(
      buildAuthoritativeEvents(config, 8n, 1_785_024_001_000n),
      /mint supply does not match stake pool/,
    );
  } finally {
    await Promise.all([primary.close(), backup.close()]);
  }
});
