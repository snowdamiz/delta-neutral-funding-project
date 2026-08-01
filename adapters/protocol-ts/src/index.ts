import { createServer } from "node:http";
import {
  buildSyntheticFundingObservation,
  buildSyntheticEvent,
  buildSyntheticFundingSettlement,
  type FundingObservationEvent,
  type FundingSettlementEvent,
  type MarketSnapshotEvent,
  type WalletObservationEvent,
} from "./contracts.js";
import { loadConfig } from "./config.js";
import { captureFundingObservations } from "./funding-sources.js";
import { buildAuthoritativeEvents } from "./sources.js";
import { fetchWalletConfig, postEvent, type WalletConfig } from "./transport.js";
import { captureWalletObservations } from "./wallet-sources.js";

const config = loadConfig();
let sequence = 1n;
let stopping = false;
let lastDelivery = "not_started";
let previousNavLamports: bigint | undefined;
let lastFundingId = "";
let lastFundingScanAtMs = 0n;
let lastWalletScanAtMs = 0n;
let sourceEndpoints: Record<string, string> = {};
let walletConfig: WalletConfig = { version: "0", wallets: [] };

type PendingCapture = {
  snapshot: MarketSnapshotEvent;
  funding: FundingSettlementEvent | undefined;
  fundingObservations: FundingObservationEvent[];
  fundingScanAtMs: bigint | undefined;
  walletObservations: WalletObservationEvent[];
  walletScanAtMs: bigint | undefined;
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
      const currentWalletConfig = await fetchWalletConfig(
        config.collectorUrl,
        config.collectorRequestTimeoutMs,
      );
      if (currentWalletConfig.version !== walletConfig.version) {
        log("info", "wallet_config_loaded", {
          version: currentWalletConfig.version,
          wallets: currentWalletConfig.wallets.length,
        });
      }
      walletConfig = currentWalletConfig;
      const observedAtMs = BigInt(Date.now());
      const fundingScanDue =
        lastFundingScanAtMs === 0n ||
        observedAtMs - lastFundingScanAtMs >= BigInt(config.fundingScanIntervalMs);
      const walletScanDue =
        walletConfig.wallets.length > 0 &&
        (
          lastWalletScanAtMs === 0n ||
          observedAtMs - lastWalletScanAtMs >= BigInt(config.walletScanIntervalMs)
        );
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
          fundingObservations: fundingScanDue
            ? [
                buildSyntheticFundingObservation(
                  sequence,
                  observedAtMs,
                  config.sessionId,
                ),
              ]
            : [],
          fundingScanAtMs: fundingScanDue ? observedAtMs : undefined,
          walletObservations: [],
          walletScanAtMs: walletScanDue ? observedAtMs : undefined,
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
        const [fundingObservations, walletObservations] = await Promise.all([
          fundingScanDue
            ? captureFundingObservations(
                config,
                sequence,
                observedAtMs,
                [captured.fundingObservation],
              )
            : Promise.resolve([]),
          walletScanDue
            ? captureWalletObservations(
                config,
                walletConfig.wallets,
                sequence,
                observedAtMs,
                lastWalletScanAtMs === 0n
                  ? observedAtMs > config.walletFillLookbackMs
                    ? observedAtMs - config.walletFillLookbackMs
                    : 0n
                  : lastWalletScanAtMs + 1n,
              )
            : Promise.resolve([]),
        ]);
        pending = {
          snapshot: captured.snapshot,
          funding: captured.funding,
          fundingObservations,
          fundingScanAtMs: fundingScanDue ? observedAtMs : undefined,
          walletObservations,
          walletScanAtMs: walletScanDue ? observedAtMs : undefined,
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
      config.collectorRequestTimeoutMs,
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
        config.collectorRequestTimeoutMs,
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
    for (const observation of capture.fundingObservations) {
      const fundingResponse = await postEvent(
        config.collectorUrl,
        config.hmacSecret,
        observation,
        config.collectorRequestTimeoutMs,
      );
      if (!fundingResponse.ok) {
        throw new Error(
          `collector returned ${fundingResponse.status}: ${await fundingResponse.text()}`,
        );
      }
    }
    if (capture.fundingObservations.length > 0) {
      log("info", "funding_scan_delivered", {
        scanId: capture.fundingObservations[0]?.payload.scanId,
        markets: capture.fundingObservations.length,
      });
    }
    for (const observation of capture.walletObservations) {
      const walletResponse = await postEvent(
        config.collectorUrl,
        config.hmacSecret,
        observation,
        config.collectorRequestTimeoutMs,
      );
      if (!walletResponse.ok) {
        throw new Error(
          `collector returned ${walletResponse.status}: ${await walletResponse.text()}`,
        );
      }
    }
    if (capture.walletObservations.length > 0) {
      log("info", "wallet_scan_delivered", {
        wallets: capture.walletObservations.length,
        fills: capture.walletObservations.reduce(
          (total, event) => total + event.payload.fills.length,
          0,
        ),
      });
    }
    previousNavLamports = capture.navLamports ?? previousNavLamports;
    lastFundingScanAtMs = capture.fundingScanAtMs ?? lastFundingScanAtMs;
    lastWalletScanAtMs = capture.walletScanAtMs ?? lastWalletScanAtMs;
    sourceEndpoints = capture.endpoints ?? sourceEndpoints;
    pending = undefined;
    lastDelivery = "accepted";
    sequence += 1n;
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
