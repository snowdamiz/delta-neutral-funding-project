import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { loadConfig } from "./config.js";
import { captureWalletObservations } from "./wallet-sources.js";

const wallet = "0x1111111111111111111111111111111111111111";

function json(response: import("node:http").ServerResponse, value: unknown): void {
  response.writeHead(200, { "content-type": "application/json" });
  response.end(JSON.stringify(value));
}

test("captures wallet positions and prices fills after measured copy latency", async () => {
  const observedAtMs = 1_785_024_000_000n;
  const server = createServer((request, response) => {
    void (async () => {
      const chunks: Buffer[] = [];
      for await (const chunk of request) chunks.push(Buffer.from(chunk));
      const body = JSON.parse(Buffer.concat(chunks).toString()) as {
        type: string;
        coin?: string;
        startTime?: number;
        user?: string;
      };
      assert.equal(body.user ?? wallet, wallet);

      if (body.type === "clearinghouseState") {
        json(response, {
          marginSummary: { accountValue: "10000", totalNtlPos: "500" },
          assetPositions: [{
            position: {
              coin: "BTC",
              szi: "0.01",
              entryPx: "50000",
              positionValue: "500",
              leverage: { type: "cross", value: 5 },
              unrealizedPnl: "3.5",
            },
          }],
        });
        return;
      }
      if (body.type === "userFillsByTime") {
        const fill = {
          coin: "BTC",
          px: "50000",
          sz: "0.01",
          side: "B",
          dir: "Open Long",
          closedPnl: "0",
          fee: "0.2",
          time: Number(observedAtMs - 250n),
          hash: `0x${"a".repeat(64)}`,
          tid: 42,
        };
        json(response, body.startTime === 0 ? Array(2000).fill(fill) : [
          fill,
          { ...fill, coin: "@107", dir: "Sell", tid: 43 },
        ]);
        return;
      }
      if (body.type === "l2Book" && body.coin === "BTC") {
        await new Promise((resolve) => setTimeout(resolve, 15));
        json(response, {
          levels: [
            [{ px: "49997", sz: "0.02", n: 1 }],
            [{ px: "50003", sz: "0.02", n: 1 }],
          ],
        });
        return;
      }
      response.writeHead(404).end();
    })();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert(address && typeof address !== "string");

  try {
    const config = loadConfig({
      ADAPTER_HMAC_SECRET: "secret",
      ADAPTER_SESSION_ID: "test-session",
      HYPERLIQUID_URLS: `http://127.0.0.1:${address.port}`,
      PAPER_NOTIONAL_USD_MICROS: "500000000",
      REQUEST_TIMEOUT_MS: "30000",
    });
    const events = await captureWalletObservations(
      config,
      [wallet],
      7n,
      observedAtMs,
      observedAtMs - 3_600_000n,
    );

    assert.equal(events.length, 1);
    assert.equal(events[0]?.payload.wallet, wallet);
    assert.equal(events[0]?.payload.accountValueUsdMicros, "10000000000");
    assert.deepEqual(events[0]?.payload.positions[0], {
      asset: "BTC",
      side: "long",
      quantityAtoms: "10000000",
      entryPriceUsdMicros: "50000000000",
      markPriceUsdMicros: "50000000000",
      leveragePpm: "5000000",
      unrealizedPnlUsdMicros: "3500000",
    });
    assert.equal(events[0]?.payload.fills[0]?.direction, "open");
    assert.equal(events[0]?.payload.fills.length, 1);
    assert.equal(events[0]?.payload.fills[0]?.copyBidPriceUsdMicros, "49997000000");
    assert.equal(events[0]?.payload.fills[0]?.copyAskPriceUsdMicros, "50003000000");
    assert.equal(events[0]?.payload.fills[0]?.copyBidDepthQualified, true);
    assert.equal(events[0]?.payload.fills[0]?.copyAskDepthQualified, true);
    const apiLatencyMs = BigInt(events[0]?.payload.apiLatencyMs ?? "0");
    assert(apiLatencyMs >= 10n, "API latency includes the copied book");
    assert.equal(
      events[0]?.payload.fills[0]?.copyObservedAtMs,
      (observedAtMs + apiLatencyMs).toString(),
    );
    assert.equal(
      events[0]?.payload.fills[0]?.copyLatencyMs,
      (250n + apiLatencyMs).toString(),
    );
    await assert.rejects(
      captureWalletObservations(config, [wallet], 8n, observedAtMs, 0n),
      /fill response reached the 2000-row limit/,
    );
  } finally {
    server.close();
  }
});
