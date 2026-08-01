import assert from "node:assert/strict";
import { test } from "node:test";
import { loadConfig } from "./config.js";

test("loads bounded adapter configuration", () => {
  const config = loadConfig({
    ADAPTER_HMAC_SECRET: "secret",
    ADAPTER_SESSION_ID: "test-session",
    COLLECTOR_URL: "http://collector:8080/v1/events",
    EMIT_INTERVAL_MS: "250",
    FUNDING_INTERVAL_EVENTS: "12",
    REQUEST_TIMEOUT_MS: "1000",
    COLLECTOR_REQUEST_TIMEOUT_MS: "120000",
    HEALTH_PORT: "8090",
    FUNDING_SCAN_INTERVAL_MS: "3600000",
  });
  assert.equal(config.emitIntervalMs, 250);
  assert.equal(config.fundingIntervalEvents, 12);
  assert.equal(config.sessionId, "test-session");
  assert.equal(config.healthPort, 8090);
  assert.equal(config.collectorRequestTimeoutMs, 120_000);
  assert.equal(config.mode, "synthetic");
  assert.equal(config.fundingScanIntervalMs, 3_600_000);
  assert.deepEqual(config.hyperliquidUrls, ["https://api.hyperliquid.xyz"]);
  assert.equal(config.walletScanIntervalMs, 60_000);
  assert.equal(
    config.kaminoLendingMarket,
    "7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF",
  );
  assert.equal(config.kaminoBorrowReserves[0]?.asset, "SOL");
  assert.equal(config.paperMaximumJitoSolAtoms, 10_000_000_000n);
  assert.throws(() => loadConfig({}), /ADAPTER_HMAC_SECRET/);
  assert.throws(
    () => loadConfig({ ADAPTER_HMAC_SECRET: "secret", EMIT_INTERVAL_MS: "0" }),
    /EMIT_INTERVAL_MS/,
  );
  assert.throws(
    () => loadConfig({ ADAPTER_HMAC_SECRET: "secret", FUNDING_INTERVAL_EVENTS: "0" }),
    /FUNDING_INTERVAL_EVENTS/,
  );
  assert.throws(
    () =>
      loadConfig({
        ADAPTER_HMAC_SECRET: "secret",
        KAMINO_BORROW_RESERVES: "SOL:not-a-key:not-a-mint",
      }),
    /KAMINO_BORROW_RESERVES/,
  );
  assert.throws(
    () => loadConfig({ ADAPTER_HMAC_SECRET: "secret", ADAPTER_SESSION_ID: "bad session" }),
    /ADAPTER_SESSION_ID/,
  );
  assert.throws(
    () =>
      loadConfig({
        ADAPTER_HMAC_SECRET: "secret",
        PAPER_MAX_JITOSOL_ATOMS: "0",
      }),
    /PAPER_MAX_JITOSOL_ATOMS/,
  );
  const keyless = loadConfig({
    ADAPTER_HMAC_SECRET: "secret",
    ADAPTER_MODE: "authoritative",
    EMIT_INTERVAL_MS: "15000",
  });
  assert.equal(keyless.jupiterApiKey, "");
  assert.throws(
    () =>
      loadConfig({
        ADAPTER_HMAC_SECRET: "secret",
        ADAPTER_MODE: "authoritative",
        EMIT_INTERVAL_MS: "14999",
      }),
    /keyless Jupiter/,
  );
  assert.throws(
    () =>
      loadConfig({
        ADAPTER_HMAC_SECRET: "secret",
        ADAPTER_MODE: "authoritative",
        JUPITER_API_KEY: "key",
        PHOENIX_URLS: "http://example.com",
      }),
    /HTTPS/,
  );
});
