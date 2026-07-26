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
    HEALTH_PORT: "8090",
  });
  assert.equal(config.emitIntervalMs, 250);
  assert.equal(config.fundingIntervalEvents, 12);
  assert.equal(config.sessionId, "test-session");
  assert.equal(config.healthPort, 8090);
  assert.equal(config.mode, "synthetic");
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
