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
import { createWalletSubscriber, websocketUrlFrom } from "./solana-wallet-subscriber.js";
import type { SolanaBatchRpc } from "./solana-candidate-snapshot.js";
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
      typeof cursor.latestSlot !== "string" ||
      !unsigned.test(cursor.latestSlot) ||
      (cursor.latestSignature.length === 0 && (
        cursor.latestSlot !== "0" ||
        cursor.captureComplete !== false ||
        typeof cursor.gapReason !== "string" ||
        cursor.gapReason.length === 0
      ))
    ) {
      throw new Error("collector returned an invalid Solana wallet cursor");
    }
    if (cursor.latestSignature.length > 0) {
      result.set(cursor.wallet, {
        signature: cursor.latestSignature,
        slot: Number(cursor.latestSlot),
      });
    }
  }
  return result;
}

function quoteSizes(value: unknown): { positionUsdMicros: bigint; exitDepthMultiple: bigint } {
  const config = object(object(value, "Solana wallet-flow state").strategyConfig, "strategy config");
  const values = object(config.values, "strategy config values");
  if (
    typeof values.positionUsdMicros !== "string" ||
    !positive.test(values.positionUsdMicros) ||
    typeof values.minimumExitDepthMultiple !== "string" ||
    !positive.test(values.minimumExitDepthMultiple)
  ) {
    throw new Error("collector returned invalid Solana strategy quote sizes");
  }
  return {
    positionUsdMicros: BigInt(values.positionUsdMicros),
    exitDepthMultiple: BigInt(values.minimumExitDepthMultiple),
  };
}

/** The broker will not fill an entry until this much later than its first
 *  eligible decision, so the follow-up quote is taken exactly then. */
function entryLatency(value: unknown): number {
  const config = object(object(value, "Solana wallet-flow state").brokerConfig, "broker config");
  const values = object(config.values, "broker config values");
  const raw = values.minimumDecisionLatencyMs;
  if (typeof raw !== "string" || !unsigned.test(raw)) {
    throw new Error("collector returned an invalid broker decision latency");
  }
  return Number(raw);
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

type FlowState = {
  wallets: string[];
  cursors: Map<string, SolanaWalletCursor>;
  openCandidates: ReturnType<typeof openMints>;
  sizes: { positionUsdMicros: bigint; exitDepthMultiple: bigint };
  entryLatencyMs: number;
};

function rpcClient(config: PollConfig): SolanaRpc {
  let rpcId = 0;
  return async (method, params) => {
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
}

function batchRpcClient(config: PollConfig): SolanaBatchRpc {
  let rpcId = 0;
  return async (calls) => {
    if (calls.length === 0) return [];
    const body = calls.map((call) => ({
      jsonrpc: "2.0",
      id: ++rpcId,
      method: call.method,
      params: call.params,
    }));
    const response = await fetch(config.rpcUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(config.timeoutMs),
    });
    if (!response.ok) throw new Error(`Solana RPC batch returned ${response.status}`);
    const parsed = await response.json();
    if (!Array.isArray(parsed)) throw new Error("Solana RPC batch returned no array");
    // Providers may reorder a batch, so match on the request id.
    const byId = new Map<number, unknown>();
    for (const raw of parsed) {
      const entry = object(raw, "Solana RPC batch entry");
      if (typeof entry.id === "number") byId.set(entry.id, entry.error === undefined ? entry.result : null);
    }
    return body.map((call) => byId.get(call.id) ?? null);
  };
}

export async function fetchFlowState(config: PollConfig): Promise<FlowState> {
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
  return {
    wallets: followedWallets(state),
    cursors: cursors(state),
    openCandidates: openMints(state),
    sizes: quoteSizes(state),
    entryLatencyMs: entryLatency(state),
  };
}

/**
 * One wallet's durable capture: page its signatures from the recorded cursor,
 * decode each acquisition, snapshot every acquired mint, then post the
 * checkpoint. Identical whether a socket notification or the periodic sweep
 * triggered it, so realtime delivery never bypasses gap detection.
 */
export async function captureWallet(
  config: PollConfig,
  state: FlowState,
  wallet: string,
  index: number,
  rpc: SolanaRpc,
  result: PollResult,
  batchRpc?: SolanaBatchRpc,
): Promise<void> {
  const capture = await captureSolanaWalletFlow({
    wallet,
    observedAtMs: config.observedAtMs,
    sessionId: `${config.sessionId}-${index}`,
    rpc,
    ...(state.cursors.has(wallet) ? { cursor: state.cursors.get(wallet)! } : {}),
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
        cohortWallets: state.wallets,
        sanctionedAddresses: config.sanctionedAddresses,
        positionUsdMicros: state.sizes.positionUsdMicros,
        exitDepthMultiple: state.sizes.exitDepthMultiple,
        ...(batchRpc === undefined ? {} : { batchRpc }),
      }),
    );
    result.snapshots += 1;
  }
  await post(config.collectorUrl, config.hmacSecret, config.timeoutMs, capture.checkpoint);
  result.checkpoints += 1;
  if (capture.checkpoint.payload.status === "gap") result.gaps += 1;
}

/** Re-quote every open candidate so the broker can act on exits. */
export async function monitorCandidates(
  config: PollConfig,
  state: FlowState,
  rpc: SolanaRpc,
  result: PollResult,
  batchRpc?: SolanaBatchRpc,
): Promise<void> {
  for (const [index, candidate] of state.openCandidates.entries()) {
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
        cohortWallets: state.wallets,
        sanctionedAddresses: config.sanctionedAddresses,
        positionUsdMicros: state.sizes.positionUsdMicros,
        exitDepthMultiple: state.sizes.exitDepthMultiple,
        ...(batchRpc === undefined ? {} : { batchRpc }),
        ...(candidate.paperPositionAtoms === undefined
          ? {}
          : { paperPositionAtoms: candidate.paperPositionAtoms }),
      }),
    );
    result.snapshots += 1;
  }
}

/** Full sweep: every wallet plus the monitor pass. The socket's safety net. */
export async function pollSolanaWalletFlow(config: PollConfig): Promise<PollResult> {
  const state = await fetchFlowState(config);
  const rpc = rpcClient(config);
  const batchRpc = batchRpcClient(config);
  const result: PollResult = { acquisitions: 0, snapshots: 0, checkpoints: 0, gaps: 0 };
  for (const [index, wallet] of state.wallets.entries()) {
    await captureWallet(config, state, wallet, index, rpc, result, batchRpc);
  }
  await monitorCandidates(config, state, rpc, result, batchRpc);
  return result;
}

/** A followed wallet just transacted: capture only that wallet, now. */
export async function captureWalletNow(
  config: PollConfig,
  wallet: string,
  settings?: () => PollConfig,
): Promise<PollResult> {
  const state = await fetchFlowState(config);
  const result: PollResult = { acquisitions: 0, snapshots: 0, checkpoints: 0, gaps: 0 };
  if (!state.wallets.includes(wallet)) return result;
  await captureWallet(
    config,
    state,
    wallet,
    state.wallets.indexOf(wallet),
    rpcClient(config),
    result,
    batchRpcClient(config),
  );
  if (result.acquisitions === 0) return result;
  // The broker holds the first eligible decision for its latency gate and
  // fills on the next quote. Take that quote as soon as the gate allows
  // rather than at the next monitor tick, so the recorded fill reflects a
  // decision acted on promptly — the measured latency is still what the
  // evidence records.
  await new Promise((resolve) => setTimeout(resolve, state.entryLatencyMs + 50));
  const next = settings ? settings() : config;
  const follow = await fetchFlowState(next);
  await monitorCandidates(next, follow, rpcClient(next), result, batchRpcClient(next));
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
  const wsUrl = process.env.SOLANA_WS_URL ?? websocketUrlFrom(rpcUrl);
  const hmacSecret = process.env.ADAPTER_HMAC_SECRET ?? "";
  const sessionId = process.env.ADAPTER_SESSION_ID ?? `solana-${Date.now()}`;
  const timeoutMs = positiveInteger(process.env.REQUEST_TIMEOUT_MS, 30_000, "REQUEST_TIMEOUT_MS");
  // The socket carries acquisition latency, so these cadences only cover
  // exits (which need fresh quotes on a clock) and completeness.
  const monitorIntervalMs = positiveInteger(
    process.env.SOLANA_MONITOR_INTERVAL_MS ?? process.env.SOLANA_WALLET_POLL_INTERVAL_MS,
    5_000,
    "SOLANA_MONITOR_INTERVAL_MS",
  );
  const sweepIntervalMs = positiveInteger(
    process.env.SOLANA_WALLET_SWEEP_INTERVAL_MS,
    60_000,
    "SOLANA_WALLET_SWEEP_INTERVAL_MS",
  );
  const maxPages = positiveInteger(
    process.env.SOLANA_WALLET_MAX_BACKFILL_PAGES,
    10,
    "SOLANA_WALLET_MAX_BACKFILL_PAGES",
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
  const log = (event: string, fields: Record<string, unknown>) =>
    console.log(JSON.stringify({ timestampMs: Date.now(), event, ...fields }));
  const fail = (event: string, error: unknown) =>
    console.error(JSON.stringify({
      timestampMs: Date.now(),
      event,
      reason: error instanceof Error ? error.message : String(error),
    }));
  const settings = (): PollConfig => ({
    collectorUrl,
    rpcUrl,
    hmacSecret,
    sessionId,
    timeoutMs,
    observedAtMs: BigInt(Date.now()),
    quote,
    sanctionedAddresses,
    maxPages,
  });

  // Every capture runs through one chain. Concurrent captures of the same
  // wallet would race its durable cursor, and concurrent snapshots would
  // multiply RPC and quote load without producing a better decision.
  let chain: Promise<unknown> = Promise.resolve();
  const serial = <T,>(work: () => Promise<T>): Promise<void> =>
    (chain = chain.then(work, work).then(() => {}, () => {}));

  const dirty = new Set<string>();
  let sweepDue = true;

  const subscriber = createWalletSubscriber({
    wsUrl,
    log: { info: (event, fields) => log(event, fields) },
    onWallet: (wallet) => {
      dirty.add(wallet);
      void serial(async () => {
        const pendingWallets = [...dirty];
        dirty.clear();
        for (const pendingWallet of pendingWallets) {
          try {
            const result = await captureWalletNow(settings(), pendingWallet, settings);
            log("solana_wallet_event_captured", { wallet: pendingWallet, ...result });
          } catch (error) {
            // A failed realtime capture is recovered by the next sweep.
            sweepDue = true;
            fail("solana_wallet_event_failed", error);
          }
        }
      });
    },
    // A socket is best-effort delivery: anything missed while it was down is
    // recovered by the cursor sweep before the stream is trusted again.
    onResubscribed: () => { sweepDue = true; },
  });

  let stopping = false;
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => { stopping = true; subscriber.close(); });
  }

  let lastSweepMs = 0;
  while (!stopping) {
    await serial(async () => {
      try {
        const state = await fetchFlowState(settings());
        subscriber.reconcile(state.wallets);
        const config = settings();
        const rpc = rpcClient(config);
        const batchRpc = batchRpcClient(config);
        const result: PollResult = { acquisitions: 0, snapshots: 0, checkpoints: 0, gaps: 0 };
        if (sweepDue || Date.now() - lastSweepMs >= sweepIntervalMs) {
          for (const [index, wallet] of state.wallets.entries()) {
            await captureWallet(config, state, wallet, index, rpc, result, batchRpc);
          }
          sweepDue = false;
          lastSweepMs = Date.now();
        }
        await monitorCandidates(config, state, rpc, result, batchRpc);
        log("solana_wallet_tick", {
          ...result,
          connected: subscriber.connected(),
          subscriptions: subscriber.subscribedWallets().length,
        });
      } catch (error) {
        fail("solana_wallet_tick_failed", error);
      }
    });
    await new Promise((resolve) => setTimeout(resolve, monitorIntervalMs));
  }
  subscriber.close();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
