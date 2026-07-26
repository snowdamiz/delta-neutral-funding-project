import { createServer } from "node:http";
import {
  buildSyntheticEvent,
  buildSyntheticFundingSettlement,
  type FundingSettlementEvent,
  type MarketSnapshotEvent,
} from "./contracts.js";
import { loadConfig } from "./config.js";
import { buildAuthoritativeEvents } from "./sources.js";
import { postEvent } from "./transport.js";

const config = loadConfig();
let sequence = 1n;
let observedAtMs = BigInt(Date.now());
let stopping = false;
let lastDelivery = "not_started";
let previousNavLamports: bigint | undefined;
let lastFundingId = "";
let sourceEndpoints: Record<string, string> = {};

type PendingCapture = {
  snapshot: MarketSnapshotEvent;
  funding: FundingSettlementEvent | undefined;
  navLamports: bigint | undefined;
  endpoints: Record<string, string> | undefined;
};

let pending: PendingCapture | undefined;

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
      mode: config.mode,
      lastDelivery,
      nextSequence: sequence.toString(),
      sourceEndpoints,
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
    mode: config.mode,
    healthPort: config.healthPort,
    collectorUrl: config.collectorUrl,
  });
});

while (!stopping) {
  try {
    if (!pending) {
      if (config.mode === "synthetic") {
        pending = {
          snapshot: buildSyntheticEvent(sequence, observedAtMs, config.sessionId),
          funding:
            sequence % BigInt(config.fundingIntervalEvents) === 0n
              ? buildSyntheticFundingSettlement(
                  sequence,
                  observedAtMs,
                  config.sessionId,
                )
              : undefined,
          navLamports: undefined,
          endpoints: undefined,
        };
      } else {
        const captured = await buildAuthoritativeEvents(
          config,
          sequence,
          observedAtMs,
          previousNavLamports,
        );
        pending = {
          snapshot: captured.snapshot,
          funding: captured.funding,
          navLamports: captured.navLamports,
          endpoints: captured.endpoints,
        };
      }
    }
    const capture = pending;
    if (!capture) throw new Error("adapter failed to create a pending capture");
    const response = await postEvent(
      config.collectorUrl,
      config.hmacSecret,
      capture.snapshot,
      config.requestTimeoutMs,
    );
    if (!response.ok) {
      throw new Error(`collector returned ${response.status}: ${await response.text()}`);
    }
    log("info", "snapshot_delivered", {
      eventId: capture.snapshot.eventId,
      sequence: sequence.toString(),
    });
    if (capture.funding && capture.funding.idempotencyKey !== lastFundingId) {
      const fundingResponse = await postEvent(
        config.collectorUrl,
        config.hmacSecret,
        capture.funding,
        config.requestTimeoutMs,
      );
      if (!fundingResponse.ok) {
        throw new Error(
          `collector returned ${fundingResponse.status}: ${await fundingResponse.text()}`,
        );
      }
      log("info", "funding_delivered", {
        eventId: capture.funding.eventId,
        sequence: sequence.toString(),
      });
      lastFundingId = capture.funding.idempotencyKey;
    }
    previousNavLamports = capture.navLamports ?? previousNavLamports;
    sourceEndpoints = capture.endpoints ?? sourceEndpoints;
    pending = undefined;
    lastDelivery = "accepted";
    sequence += 1n;
    observedAtMs = BigInt(Date.now());
  } catch (error) {
    lastDelivery = "error";
    log("error", "event_delivery_failed", {
      sequence: sequence.toString(),
      mode: config.mode,
      reason: error instanceof Error ? error.message : String(error),
    });
  }
  await new Promise((resolve) => setTimeout(resolve, config.emitIntervalMs));
}
