import { createServer } from "node:http";
import { buildSyntheticEvent } from "./contracts.js";
import { loadConfig } from "./config.js";
import { postEvent } from "./transport.js";

const config = loadConfig();
let sequence = 1n;
let stopping = false;
let lastDelivery = "not_started";

function log(level: string, event: string, fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ timestampMs: Date.now(), level, event, ...fields }));
}

const health = createServer((_request, response) => {
  response.writeHead(lastDelivery === "error" ? 503 : 200, {
    "content-type": "application/json",
  });
  response.end(
    JSON.stringify({
      status: lastDelivery === "error" ? "degraded" : "ok",
      mode: "synthetic",
      lastDelivery,
      nextSequence: sequence.toString(),
    }),
  );
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    stopping = true;
    health.close();
  });
}

health.listen(config.healthPort, "0.0.0.0", () => {
  log("info", "adapter_started", {
    mode: "synthetic",
    healthPort: config.healthPort,
    collectorUrl: config.collectorUrl,
  });
});

while (!stopping) {
  const event = buildSyntheticEvent(sequence, BigInt(Date.now()));
  try {
    const response = await postEvent(
      config.collectorUrl,
      config.hmacSecret,
      event,
      config.requestTimeoutMs,
    );
    if (!response.ok) {
      throw new Error(`collector returned ${response.status}: ${await response.text()}`);
    }
    lastDelivery = "accepted";
    log("info", "snapshot_delivered", { eventId: event.eventId, sequence: sequence.toString() });
    sequence += 1n;
  } catch (error) {
    lastDelivery = "error";
    log("error", "snapshot_delivery_failed", {
      sequence: sequence.toString(),
      reason: error instanceof Error ? error.message : String(error),
    });
  }
  await new Promise((resolve) => setTimeout(resolve, config.emitIntervalMs));
}
