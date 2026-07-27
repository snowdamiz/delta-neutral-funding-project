import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { test } from "node:test";
import { loadConfig } from "./config.js";
import { buildAuthoritativeEvents } from "./sources.js";

const solMint = "So11111111111111111111111111111111111111112";
const jitoMint = "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn";
const usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const phoenixSolMarket = "71Si24E4uc3oCaPbPZTozC1ptSNNqygjjebxSmErSsC2";
const billion = 1_000_000_000n;
let expectedJitoQuoteAtoms =
  500_000_000n * billion * billion / (1_234_567_890n * 150_020_000n);
let expectedSolQuoteAtoms =
  (expectedJitoQuoteAtoms * 1_234_567_890n + billion - 1n) / billion;

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
  let mintSupply = 10_000_000_000n;
  let marketPubkey = phoenixSolMarket;
  let rejectDoubledQuotes = false;
  let expectedJupiterKey: string | undefined = "test-jupiter-key";
  const jupiterRequests = new Set<string>();
  const keylessRequestTimes: number[] = [];
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
          marketPubkey,
          baseLotsDecimals: 2,
          leverageTiers: [
            { maxLeverage: 25, maxSizeBaseLots: "300" },
            { maxLeverage: 10, maxSizeBaseLots: "50000000" },
          ],
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
          rates: [{ timestamp: 1785020401, fundingRatePercentage: "0.025000" }],
        });
        return;
      }
      if (url.pathname === "/phoenix/candles") {
        assert.equal(url.searchParams.get("symbol"), "SOL");
        assert.equal(url.searchParams.get("timeframe"), "1h");
        assert.equal(url.searchParams.get("startTime"), "1785016800000");
        assert.equal(url.searchParams.get("endTime"), "1785020400000");
        json(response, [{
          time: 1785016800000,
          close: 149.93,
          markClose: 149.94,
        }]);
        return;
      }
      if (url.pathname === "/rpc") {
        const pool = Buffer.alloc(611);
        pool[0] = 1;
        pool.writeBigUInt64LE(12_345_678_900n, 258);
        pool.writeBigUInt64LE(10_000_000_000n, 266);
        pool.writeBigUInt64LE(777n, 274);
        const mint = Buffer.alloc(82);
        mint.writeBigUInt64LE(mintSupply, 36);
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
        assert.equal(request.headers["x-api-key"], expectedJupiterKey);
        if (expectedJupiterKey === undefined) {
          keylessRequestTimes.push(Date.now());
        }
        const input = url.searchParams.get("inputMint");
        const output = url.searchParams.get("outputMint");
        const swapMode = url.searchParams.get("swapMode");
        const amount = BigInt(url.searchParams.get("amount") ?? "0");
        jupiterRequests.add(`${input}:${output}:${amount}:${swapMode}`);
        const solExitRate =
          amount === expectedSolQuoteAtoms * 2n ? 149_000_000n : 149_950_000n;
        const jitoExitRate =
          amount === expectedJitoQuoteAtoms * 2n ? 180_000_000n : 185_050_000n;
        if (
          rejectDoubledQuotes &&
          swapMode === "ExactIn" &&
          (amount === expectedSolQuoteAtoms * 2n ||
            amount === expectedJitoQuoteAtoms * 2n)
        ) {
          json(response, { error: "2x route unavailable" }, 503);
          return;
        }
        const quote =
          input === solMint && output === usdcMint
            ? [
                amount.toString(),
                (amount * solExitRate / billion).toString(),
                "ExactIn",
              ]
            : input === usdcMint && output === solMint
              ? [
                  ((amount * 150_050_000n + billion - 1n) / billion).toString(),
                  amount.toString(),
                  "ExactOut",
                ]
              : input === jitoMint && output === usdcMint
                ? [
                    amount.toString(),
                    (amount * jitoExitRate / billion).toString(),
                    "ExactIn",
                  ]
                : input === usdcMint && output === jitoMint
                  ? [
                      ((amount * 185_250_000n + billion - 1n) / billion)
                        .toString(),
                      amount.toString(),
                      "ExactOut",
                    ]
                  : null;
        assert(quote);
        assert.equal(swapMode, quote[2]);
        const target =
          input === solMint || output === solMint
            ? expectedSolQuoteAtoms
            : expectedJitoQuoteAtoms;
        assert(
          amount === target ||
            (swapMode === "ExactIn" && amount === target * 2n),
        );
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
      REQUEST_TIMEOUT_MS: "30000",
      SOURCE_MAX_SLOT_DRIFT: "10",
      SOURCE_MAX_FUNDING_AGE_MS: "7200000",
      PAPER_MAX_JITOSOL_ATOMS: "10000000000",
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
    assert.equal(captured.snapshot.payload.epoch, "777");
    assert.equal(captured.snapshot.payload.totalPoolLamports, "12345678900");
    assert.equal(captured.snapshot.payload.supplyAtoms, "10000000000");
    assert.equal(captured.snapshot.payload.priorNavLamports, "1234000000");
    assert.equal(captured.snapshot.payload.shortReceiptPpm, "250");
    const solBidOutput = expectedSolQuoteAtoms * 149_950_000n / billion;
    const solAskInput =
      (expectedSolQuoteAtoms * 150_050_000n + billion - 1n) / billion;
    const expectedSolBid = solBidOutput * billion / expectedSolQuoteAtoms;
    const expectedSolAsk =
      (solAskInput * billion + expectedSolQuoteAtoms - 1n) /
      expectedSolQuoteAtoms;
    const jitoBidOutput =
      expectedJitoQuoteAtoms * 185_050_000n / billion;
    const jitoAskInput =
      (expectedJitoQuoteAtoms * 185_250_000n + billion - 1n) / billion;
    const expectedJitoBid =
      jitoBidOutput * billion / expectedJitoQuoteAtoms;
    const expectedJitoAsk =
      (jitoAskInput * billion + expectedJitoQuoteAtoms - 1n) /
      expectedJitoQuoteAtoms;
    const expectedHedge =
      expectedJitoQuoteAtoms * expectedJitoBid / expectedSolBid;
    const doubledSolAtoms = expectedSolQuoteAtoms * 2n;
    const doubledJitoAtoms = expectedJitoQuoteAtoms * 2n;
    const doubledSolOutput = doubledSolAtoms * 149_000_000n / billion;
    const doubledJitoOutput = doubledJitoAtoms * 180_000_000n / billion;
    const expectedJitoExitDepth =
      doubledJitoOutput * doubledSolAtoms / doubledSolOutput;
    const expectedNotional = expectedHedge * expectedSolBid / billion;
    const expectedPerpNotional =
      (expectedHedge * 150_020_000n + billion - 1n) / billion;
    const expectedInitialMargin = (expectedPerpNotional + 9n) / 10n;
    const expectedMaintenance = (expectedInitialMargin * 5_000n + 9_999n) /
      10_000n;
    assert.equal(
      captured.snapshot.payload.solSpotBidPriceUsdMicros,
      expectedSolBid.toString(),
    );
    assert.equal(
      captured.snapshot.payload.solSpotAskPriceUsdMicros,
      expectedSolAsk.toString(),
    );
    assert.equal(
      captured.snapshot.payload.jitosolSpotBidPriceUsdMicros,
      expectedJitoBid.toString(),
    );
    assert.equal(
      captured.snapshot.payload.jitosolSpotAskPriceUsdMicros,
      expectedJitoAsk.toString(),
    );
    assert.equal(
      captured.snapshot.payload.jitosolAtoms,
      expectedJitoQuoteAtoms.toString(),
    );
    assert.equal(captured.snapshot.payload.perpBidPriceUsdMicros, "149980000");
    assert.equal(captured.snapshot.payload.perpAskPriceUsdMicros, "150020000");
    assert.equal(captured.snapshot.payload.perpExitDepthLamports, "80000000000");
    assert.equal(
      captured.snapshot.payload.solExitDepthLamports,
      doubledSolAtoms.toString(),
    );
    assert.equal(
      captured.snapshot.payload.jitosolExitDepthLamports,
      expectedJitoExitDepth.toString(),
    );
    assert.equal(
      captured.snapshot.payload.notionalUsdMicros,
      expectedNotional.toString(),
    );
    assert.equal(captured.snapshot.payload.perpFeePpm, "400");
    assert.equal(
      captured.snapshot.payload.maintenanceRequirementUsdMicros,
      expectedMaintenance.toString(),
    );
    assert.equal(
      captured.snapshot.payload.liquidationDistanceBps,
      ((500_000_000n - expectedMaintenance) * 10_000n / expectedPerpNotional)
        .toString(),
    );
    assert.equal(captured.navLamports, 1_234_567_890n);
    assert.equal(captured.funding.payload.venuePaymentId, "phoenix:SOL:1785020401");
    assert.equal(captured.funding.payload.realizedShortRatePpm, "250");
    assert.equal(captured.funding.payload.solPriceUsdMicros, "149940000");
    assert(
      jupiterRequests.has(
        `${solMint}:${usdcMint}:${doubledSolAtoms}:ExactIn`,
      ),
    );
    assert(
      jupiterRequests.has(
        `${jitoMint}:${usdcMint}:${doubledJitoAtoms}:ExactIn`,
      ),
    );
    assert.match(captured.snapshot.rawPayloadHash, /^[0-9a-f]{64}$/);
    assert(primaryRequests >= 3);

    marketPubkey = "11111111111111111111111111111111";
    await assert.rejects(
      buildAuthoritativeEvents(config, 8n, 1_785_024_001_000n),
      /Phoenix SOL market identity changed/,
    );
    marketPubkey = phoenixSolMarket;

    rejectDoubledQuotes = true;
    await assert.rejects(
      buildAuthoritativeEvents(config, 8n, 1_785_024_001_000n),
      /Jupiter sources failed/,
    );
    rejectDoubledQuotes = false;
    expectedJupiterKey = undefined;
    expectedJitoQuoteAtoms = 2_000_000_000n;
    expectedSolQuoteAtoms =
      (expectedJitoQuoteAtoms * 1_234_567_890n + billion - 1n) / billion;
    const keylessConfig = loadConfig({
      ADAPTER_HMAC_SECRET: "secret",
      ADAPTER_MODE: "authoritative",
      ADAPTER_SESSION_ID: "source-test-keyless",
      EMIT_INTERVAL_MS: "15000",
      PHOENIX_URLS: `${backup.url}/phoenix`,
      SOLANA_RPC_URLS: `${backup.url}/rpc`,
      JUPITER_URLS: `${backup.url}/jupiter`,
      REQUEST_TIMEOUT_MS: "30000",
      SOURCE_MAX_SLOT_DRIFT: "10",
      SOURCE_MAX_FUNDING_AGE_MS: "7200000",
      PAPER_MAX_JITOSOL_ATOMS: "2000000000",
      PAPER_NOTIONAL_USD_MICROS: "500000000",
      PAPER_COLLATERAL_USD_MICROS: "500000000",
      PAPER_COSTS_USD_MICROS: "200000",
      PAPER_RISK_HAIRCUT_USD_MICROS: "50000",
      PAPER_SLIPPAGE_BPS: "5",
    });
    const keyless = await buildAuthoritativeEvents(
      keylessConfig,
      8n,
      1_785_024_001_000n,
    );
    assert.equal(keyless.snapshot.source, "authoritative:source-test-keyless");
    assert.equal(keyless.snapshot.payload.jitosolAtoms, "2000000000");
    assert.deepEqual(keyless.funding, captured.funding);
    assert.equal(keylessRequestTimes.length, 6);
    assert(
      keylessRequestTimes
        .slice(1)
        .every((time, index) => time - keylessRequestTimes[index]! >= 1_900),
    );

    expectedJupiterKey = "test-jupiter-key";
    expectedJitoQuoteAtoms =
      500_000_000n * billion * billion / (1_234_567_890n * 150_020_000n);
    expectedSolQuoteAtoms =
      (expectedJitoQuoteAtoms * 1_234_567_890n + billion - 1n) / billion;
    mintSupply = 9_999_999_999n;
    const burned = await buildAuthoritativeEvents(
      config,
      9n,
      1_785_024_001_000n,
    );
    assert.equal(burned.snapshot.payload.supplyAtoms, "10000000000");

    mintSupply = 10_000_000_001n;
    await assert.rejects(
      buildAuthoritativeEvents(config, 10n, 1_785_024_001_000n),
      /mint supply exceeds stake pool accounting/,
    );
  } finally {
    await Promise.all([primary.close(), backup.close()]);
  }
});
