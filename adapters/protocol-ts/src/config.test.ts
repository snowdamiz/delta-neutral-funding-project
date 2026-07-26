import assert from "node:assert/strict";
import { test } from "node:test";
import { loadConfig } from "./config.js";

test("loads bounded synthetic adapter configuration", () => {
  const config = loadConfig({
    ADAPTER_HMAC_SECRET: "secret",
    COLLECTOR_URL: "http://collector:8080/v1/events",
    EMIT_INTERVAL_MS: "250",
    REQUEST_TIMEOUT_MS: "1000",
    HEALTH_PORT: "8090",
  });
  assert.equal(config.emitIntervalMs, 250);
  assert.equal(config.healthPort, 8090);
  assert.throws(() => loadConfig({}), /ADAPTER_HMAC_SECRET/);
  assert.throws(
    () => loadConfig({ ADAPTER_HMAC_SECRET: "secret", EMIT_INTERVAL_MS: "0" }),
    /EMIT_INTERVAL_MS/,
  );
});
