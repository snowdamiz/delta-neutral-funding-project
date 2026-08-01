import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { loadConfig } from "./config.js";
import {
  captureFundingObservations,
  type FundingObservationRow,
} from "./funding-sources.js";

function json(response: import("node:http").ServerResponse, value: unknown): void {
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify(value));
}

test("captures every venue market and depth-qualifies only executable spot pairs", async () => {
  const server = createServer((request, response) => {
    void (async () => {
      const url = new URL(request.url ?? "/", "http://127.0.0.1");
      if (url.pathname === "/hl/info") {
        const chunks: Buffer[] = [];
        for await (const chunk of request) chunks.push(Buffer.from(chunk));
        const body = JSON.parse(Buffer.concat(chunks).toString()) as {
          type: string;
          coin?: string;
          startTime?: number;
        };
        if (body.type === "metaAndAssetCtxs") {
          json(response, [
            { universe: [
              { name: "BTC", szDecimals: 5, maxLeverage: 40 },
              { name: "kPEPE", szDecimals: 2, maxLeverage: 5 },
            ] },
            [
              {
                funding: "0.0000125", markPx: "50000", openInterest: "10",
                midPx: "50000", impactPxs: ["49999", "50001"],
              },
              {
                funding: "0.000025", markPx: "2", openInterest: "1000",
                midPx: "2", impactPxs: ["1.99", "2.01"],
              },
            ],
          ]);
          return;
        }
        if (body.type === "spotMetaAndAssetCtxs") {
          json(response, [
            {
              tokens: [
                { name: "USDC", index: 0 },
                { name: "BTC", index: 1 },
              ],
              universe: [{ name: "BTC/USDC", tokens: [1, 0], index: 0 }],
            },
            [{ coin: "BTC/USDC", markPx: "50000", midPx: "50000" }],
          ]);
          return;
        }
        if (body.type === "l2Book" && body.coin === "BTC") {
          json(response, {
            coin: "BTC",
            levels: [
              [
                { px: "49999", sz: "0.005", n: 1 },
                { px: "49998", sz: "0.025", n: 1 },
              ],
              [
                { px: "50001", sz: "0.005", n: 1 },
                { px: "50002", sz: "0.025", n: 1 },
              ],
            ],
          });
          return;
        }
        if (body.type === "l2Book" && body.coin === "BTC/USDC") {
          json(response, {
            coin: "BTC/USDC",
            levels: [
              [
                { px: "49998", sz: "0.005", n: 1 },
                { px: "49997", sz: "0.025", n: 1 },
              ],
              [
                { px: "50002", sz: "0.005", n: 1 },
                { px: "50003", sz: "0.025", n: 1 },
              ],
            ],
          });
          return;
        }
        if (body.type === "l2Book" && body.coin === "kPEPE") {
          json(response, {
            coin: "kPEPE",
            levels: [
              [{ px: "1.99", sz: "1000", n: 1 }],
              [{ px: "2.01", sz: "1000", n: 1 }],
            ],
          });
          return;
        }
        if (body.type === "fundingHistory" && body.coin === "BTC") {
          assert.equal(body.startTime, 1_784_415_600_000);
          json(response, Array.from({ length: 169 }, (_, index) => ({
            coin: "BTC",
            fundingRate: index === 168 ? "0.00001" : "0.00002",
            premium: "0.000005",
            time: 1_784_415_600_000 + index * 3_600_000,
          })));
          return;
        }
        if (body.type === "fundingHistory" && body.coin === "kPEPE") {
          json(response, [{
            coin: "kPEPE",
            fundingRate: "0.00002",
            premium: "0",
            time: 1_785_020_400_000,
          }]);
          return;
        }
      }
      if (
        url.pathname ===
        "/kamino/kamino-market/7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF/reserves/metrics"
      ) {
        json(response, [{
          reserve: "d4A2prbA2whesmvHaL88BH6Ewn5N4bTSU2Ze8P6Bc4Q",
          liquidityToken: "SOL",
          liquidityTokenMint: "So11111111111111111111111111111111111111112",
          borrowApy: "0.0876",
          totalSupplyUsd: "1000",
          totalBorrowUsd: "400",
        }]);
        return;
      }
      response.writeHead(404).end();
    })();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert(address && typeof address !== "string");

  try {
    const base = `http://127.0.0.1:${address.port}`;
    const config = loadConfig({
      ADAPTER_HMAC_SECRET: "secret",
      ADAPTER_SESSION_ID: "test-session",
      HYPERLIQUID_URLS: `${base}/hl`,
      KAMINO_URLS: `${base}/kamino`,
      KAMINO_BORROW_RESERVES:
        "SOL:d4A2prbA2whesmvHaL88BH6Ewn5N4bTSU2Ze8P6Bc4Q:So11111111111111111111111111111111111111112",
      PAPER_NOTIONAL_USD_MICROS: "500000000",
      PAPER_SLIPPAGE_BPS: "50",
      REQUEST_TIMEOUT_MS: "30000",
    });
    const phoenix: FundingObservationRow = {
      venue: "phoenix",
      asset: "KPEPE",
      instrument: "KPEPE-PERP",
      sourceObservedAtMs: "0",
      sourceStatus: "valid",
      fundingRatePpmPerHour: "5",
      fundingHistory: [{ observedAtMs: "1785020400000", ratePpm: "5" }],
      realizedFundingRatePpm: "5",
      realizedFundingAtMs: "1785020400000",
      markPriceUsdMicros: "2000000",
      openInterestUsdMicros: "0",
      spotBidPriceUsdMicros: "0",
      spotAskPriceUsdMicros: "0",
      perpBidPriceUsdMicros: "1990000",
      perpAskPriceUsdMicros: "2010000",
      spotExitDepthAtoms: "0",
      perpExitDepthAtoms: "1000000000000",
      depthQualified: false,
      marginStatus: "valid",
      maintenanceMarginPpm: "50000",
      raw: "phoenix-kpepe",
    };
    const observations = await captureFundingObservations(
      config,
      7n,
      1_785_024_000_000n,
      [phoenix],
    );

    assert.equal(observations.length, 3);
    assert.deepEqual(
      observations.map((event) => event.source),
      [
        "hyperliquid-funding-observation:BTC",
        "hyperliquid-funding-observation:KPEPE",
        "phoenix-funding-observation:KPEPE",
      ],
    );
    assert(observations.every((event) => event.sourceSequence === "test-session:scan-7"));
    assert(observations.every((event) => event.payload.scanSize === "3"));
    assert.deepEqual(
      observations.map((event) => `${event.payload.venue}:${event.payload.asset}`),
      ["hyperliquid:BTC", "hyperliquid:KPEPE", "phoenix:KPEPE"],
    );
    assert.equal(observations[1]?.payload.instrument, "KPEPE-PERP");
    assert.equal(observations[0]?.payload.fundingRatePpmPerHour, "12");
    assert.equal(observations[0]?.payload.depthQualified, true);
    assert.equal(observations[0]?.payload.spotExitDepthAtoms, "30000000");
    assert.equal(observations[0]?.payload.perpExitDepthAtoms, "30000000");
    assert.equal(observations[0]?.payload.spotBidPriceUsdMicros, "49997500000");
    assert.equal(observations[0]?.payload.spotAskPriceUsdMicros, "50002500000");
    assert.equal(observations[0]?.payload.perpBidPriceUsdMicros, "49998500000");
    assert.equal(observations[0]?.payload.perpAskPriceUsdMicros, "50001500000");
    assert.equal(observations[0]?.payload.realizedFundingRatePpm, "10");
    assert.equal(observations[0]?.payload.realizedFundingAtMs, "1785020400000");
    assert.equal(observations[0]?.payload.fundingHistory.length, 169);
    assert.deepEqual(observations[0]?.payload.fundingHistory.at(-1), {
      observedAtMs: "1785020400000",
      ratePpm: "10",
    });
    assert.equal(observations[0]?.payload.marginStatus, "valid");
    assert.equal(observations[0]?.payload.maintenanceMarginPpm, "12500");
    assert.equal(observations[1]?.payload.marginStatus, "valid");
    assert.equal(observations[1]?.payload.maintenanceMarginPpm, "100000");
    assert.equal(observations[1]?.payload.depthQualified, false);
    assert.equal(observations[1]?.payload.perpExitDepthAtoms, "1000000000000");
    assert.equal(observations[1]?.payload.realizedFundingRatePpm, "20");
    const btcBorrow = observations[0]?.payload as unknown as Record<string, unknown>;
    assert.equal(btcBorrow.borrowSourceStatus, "unavailable");
  } finally {
    server.close();
  }
});
