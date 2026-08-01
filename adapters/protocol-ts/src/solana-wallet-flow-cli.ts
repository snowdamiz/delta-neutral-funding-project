import { pathToFileURL } from "node:url";
import {
  createJupiterQuote,
  snapshotSolanaCandidate,
  type JupiterQuote,
} from "./solana-candidate-snapshot.js";
import {
  captureSolanaWalletFlow,
  type SolanaRpc,
  type SolanaWalletAcquisitionEvent,
  type SolanaWalletCursor,
} from "./solana-wallet-flow.js";
import { signBody } from "./transport.js";

type PollConfig = {
  collectorUrl: string;
  rpcUrl: string;
  hmacSecret: string;
  sessionId: string;
  timeoutMs: number;
  observedAtMs: bigint;
  pageSize?: number;
  maxPages?: number;
  quote: JupiterQuote;
  sanctionedAddresses: Set<string>;
};

type PollResult = {
  acquisitions: number;
  snapshots: number;
  checkpoints: number;
  gaps: number;
};

const publicKey = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const unsigned = /^(0|[1-9][0-9]*)$/;
const positive = /^[1-9][0-9]*$/;

function object(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function cursors(value: unknown): Map<string, SolanaWalletCursor> {
  const root = object(value, "Solana wallet-flow state");
  if (!Array.isArray(root.cursors) || root.cursors.length > 100) {
    throw new Error("collector returned invalid Solana wallet cursors");
  }
  const result = new Map<string, SolanaWalletCursor>();
  for (const raw of root.cursors) {
    const cursor = object(raw, "Solana wallet cursor");
    if (
      typeof cursor.wallet !== "string" ||
      !publicKey.test(cursor.wallet) ||
      typeof cursor.latestSignature !== "string" ||
      cursor.latestSignature.length === 0 ||
      typeof cursor.latestSlot !== "string" ||
      !unsigned.test(cursor.latestSlot)
    ) {
      throw new Error("collector returned an invalid Solana wallet cursor");
    }
    result.set(cursor.wallet, {
      signature: cursor.latestSignature,
      slot: Number(cursor.latestSlot),
    });
  }
  return result;
}

function followedWallets(value: unknown): string[] {
  const config = object(object(value, "Solana wallet-flow state").followedWallets, "followed wallets");
  if (
    typeof config.version !== "string" ||
    !unsigned.test(config.version) ||
    config.maximumWallets !== "100" ||
    !Array.isArray(config.wallets) ||
    config.wallets.length > 100 ||
    config.wallets.some((wallet) => typeof wallet !== "string" || !publicKey.test(wallet)) ||
    new Set(config.wallets).size !== config.wallets.length
  ) {
    throw new Error("collector returned invalid followed Solana wallets");
  }
  return config.wallets as string[];
}

function openMints(value: unknown): Array<{
  acquisition: SolanaWalletAcquisitionEvent;
  paperPositionAtoms?: bigint;
}> {
  const root = object(value, "Solana wallet-flow state");
  if (!Array.isArray(root.openMints) || root.openMints.length > 100) {
    throw new Error("collector returned invalid open Solana candidates");
  }
  return root.openMints.map((raw) => {
    const item = object(raw, "open Solana candidate");
    if (item.decision !== "WATCH" && item.decision !== "ENTER"
      && !(item.decision === "REJECT" && item.positionAtoms !== undefined && item.positionAtoms !== null)) {
      throw new Error("collector returned invalid open Solana decision");
    }
    const acquisition = object(item.acquisition, "open Solana acquisition");
    const payload = object(acquisition.payload, "open Solana acquisition payload");
    if (
      acquisition.schemaVersion !== 1
      || acquisition.eventType !== "SolanaWalletAcquisition"
      || typeof acquisition.eventId !== "string"
      || acquisition.eventId.length === 0
      || typeof acquisition.sourceSlot !== "string"
      || !unsigned.test(acquisition.sourceSlot)
      || typeof acquisition.observedAtMs !== "string"
      || !unsigned.test(acquisition.observedAtMs)
      || typeof acquisition.rawPayloadHash !== "string"
      || !/^[0-9a-f]{64}$/.test(acquisition.rawPayloadHash)
      || typeof payload.wallet !== "string"
      || !publicKey.test(payload.wallet)
      || typeof payload.signature !== "string"
      || payload.signature.length === 0
      || typeof payload.confirmedAtMs !== "string"
      || !unsigned.test(payload.confirmedAtMs)
      || typeof payload.inputMint !== "string"
      || !publicKey.test(payload.inputMint)
      || typeof payload.inputAmountAtoms !== "string"
      || !positive.test(payload.inputAmountAtoms)
      || typeof payload.outputMint !== "string"
      || !publicKey.test(payload.outputMint)
      || typeof payload.outputAmountAtoms !== "string"
      || !positive.test(payload.outputAmountAtoms)
      || typeof payload.outputDecimals !== "string"
      || !unsigned.test(payload.outputDecimals)
      || !Array.isArray(payload.routePrograms)
      || payload.routePrograms.length === 0
      || payload.routePrograms.length > 32
      || payload.routePrograms.some((program) => typeof program !== "string" || !publicKey.test(program))
    ) {
      throw new Error("collector returned invalid open Solana acquisition");
    }
    const positionAtoms = item.positionAtoms;
    if (positionAtoms !== undefined && positionAtoms !== null
      && (typeof positionAtoms !== "string" || !positive.test(positionAtoms))) {
      throw new Error("collector returned invalid Solana paper position");
    }
    return {
      acquisition: acquisition as unknown as SolanaWalletAcquisitionEvent,
      ...(positionAtoms === undefined || positionAtoms === null
        ? {}
        : { paperPositionAtoms: BigInt(positionAtoms as string) }),
    };
  });
}

async function post(
  collectorUrl: string,
  hmacSecret: string,
  timeoutMs: number,
  event: unknown,
): Promise<void> {
  const body = JSON.stringify(event);
  const response = await fetch(collectorUrl, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-adapter-signature": signBody(hmacSecret, body),
    },
    body,
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) {
    throw new Error(`collector returned ${response.status}: ${await response.text()}`);
  }
}

export async function pollSolanaWalletFlow(config: PollConfig): Promise<PollResult> {
  if (!Number.isSafeInteger(config.timeoutMs) || config.timeoutMs <= 0) {
    throw new Error("request timeout must be positive");
  }
  const stateUrl = new URL("/v1/solana-wallet-flow", config.collectorUrl);
  const stateResponse = await fetch(stateUrl, {
    headers: { accept: "application/json" },
    signal: AbortSignal.timeout(config.timeoutMs),
  });
  if (!stateResponse.ok) throw new Error(`collector state returned ${stateResponse.status}`);
  const state = await stateResponse.json();
  const wallets = followedWallets(state);
  const durableCursors = cursors(state);
  const openCandidates = openMints(state);
  let rpcId = 0;
  const rpc: SolanaRpc = async (method, params) => {
    const response = await fetch(config.rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
      signal: AbortSignal.timeout(config.timeoutMs),
    });
    if (!response.ok) throw new Error(`Solana RPC returned ${response.status}`);
    const body = object(await response.json(), "Solana RPC response");
    if (body.error !== undefined) {
      throw new Error(`Solana RPC ${method} failed: ${JSON.stringify(body.error)}`);
    }
    return body.result;
  };
  const result: PollResult = { acquisitions: 0, snapshots: 0, checkpoints: 0, gaps: 0 };

  for (const [index, wallet] of wallets.entries()) {
    const capture = await captureSolanaWalletFlow({
      wallet,
      observedAtMs: config.observedAtMs,
      sessionId: `${config.sessionId}-${index}`,
      rpc,
      ...(durableCursors.has(wallet) ? { cursor: durableCursors.get(wallet)! } : {}),
      ...(config.pageSize === undefined ? {} : { pageSize: config.pageSize }),
      ...(config.maxPages === undefined ? {} : { maxPages: config.maxPages }),
    });
    for (const acquisition of capture.acquisitions) {
      await post(config.collectorUrl, config.hmacSecret, config.timeoutMs, acquisition);
      result.acquisitions += 1;
      await post(
        config.collectorUrl,
        config.hmacSecret,
        config.timeoutMs,
        await snapshotSolanaCandidate({
          acquisition,
          observedAtMs: config.observedAtMs,
          sessionId: `${config.sessionId}-${index}`,
          rpc,
          quote: config.quote,
          cohortWallets: wallets,
          sanctionedAddresses: config.sanctionedAddresses,
        }),
      );
      result.snapshots += 1;
    }
    await post(config.collectorUrl, config.hmacSecret, config.timeoutMs, capture.checkpoint);
    result.checkpoints += 1;
    if (capture.checkpoint.payload.status === "gap") result.gaps += 1;
  }
  for (const [index, candidate] of openCandidates.entries()) {
    await post(
      config.collectorUrl,
      config.hmacSecret,
      config.timeoutMs,
      await snapshotSolanaCandidate({
        acquisition: candidate.acquisition,
        observedAtMs: config.observedAtMs,
        sessionId: `${config.sessionId}-monitor-${index}`,
        rpc,
        quote: config.quote,
        cohortWallets: wallets,
        sanctionedAddresses: config.sanctionedAddresses,
        ...(candidate.paperPositionAtoms === undefined
          ? {}
          : { paperPositionAtoms: candidate.paperPositionAtoms }),
      }),
    );
    result.snapshots += 1;
  }
  return result;
}

function positiveInteger(value: string | undefined, fallback: number, name: string): number {
  const parsed = Number(value ?? fallback);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

async function main(): Promise<void> {
  const collectorUrl = process.env.COLLECTOR_URL ?? "http://127.0.0.1:8080/v1/events";
  const rpcUrl = process.env.SOLANA_RPC_URL ?? "https://api.mainnet-beta.solana.com";
  const hmacSecret = process.env.ADAPTER_HMAC_SECRET ?? "";
  const sessionId = process.env.ADAPTER_SESSION_ID ?? `solana-${Date.now()}`;
  const timeoutMs = positiveInteger(process.env.REQUEST_TIMEOUT_MS, 30_000, "REQUEST_TIMEOUT_MS");
  const intervalMs = positiveInteger(
    process.env.SOLANA_WALLET_POLL_INTERVAL_MS,
    5_000,
    "SOLANA_WALLET_POLL_INTERVAL_MS",
  );
  const quote = createJupiterQuote(
    process.env.JUPITER_URL ?? "https://api.jup.ag/swap/v1",
    process.env.JUPITER_API_KEY ?? "",
    timeoutMs,
  );
  const sanctionedAddresses = new Set(
    (process.env.SOLANA_SANCTIONED_ADDRESSES ?? "")
      .split(",")
      .map((address) => address.trim())
      .filter(Boolean),
  );
  let stopping = false;
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => { stopping = true; });
  }
  while (!stopping) {
    try {
      const result = await pollSolanaWalletFlow({
        collectorUrl,
        rpcUrl,
        hmacSecret,
        sessionId,
        timeoutMs,
        observedAtMs: BigInt(Date.now()),
        quote,
        sanctionedAddresses,
        maxPages: positiveInteger(
          process.env.SOLANA_WALLET_MAX_BACKFILL_PAGES,
          10,
          "SOLANA_WALLET_MAX_BACKFILL_PAGES",
        ),
      });
      console.log(JSON.stringify({ timestampMs: Date.now(), event: "solana_wallet_poll", ...result }));
    } catch (error) {
      console.error(JSON.stringify({
        timestampMs: Date.now(),
        event: "solana_wallet_poll_failed",
        reason: error instanceof Error ? error.message : String(error),
      }));
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
