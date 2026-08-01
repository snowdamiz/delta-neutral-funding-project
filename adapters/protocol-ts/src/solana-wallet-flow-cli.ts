import { pathToFileURL } from "node:url";
import {
  captureSolanaWalletFlow,
  type SolanaRpc,
  type SolanaWalletCursor,
} from "./solana-wallet-flow.js";
import { signBody } from "./transport.js";

type PollConfig = {
  wallets: string[];
  collectorUrl: string;
  rpcUrl: string;
  hmacSecret: string;
  sessionId: string;
  timeoutMs: number;
  observedAtMs: bigint;
  pageSize?: number;
  maxPages?: number;
};

type PollResult = {
  acquisitions: number;
  checkpoints: number;
  gaps: number;
};

const publicKey = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const unsigned = /^(0|[1-9][0-9]*)$/;

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
  if (
    config.wallets.length === 0 ||
    config.wallets.length > 100 ||
    new Set(config.wallets).size !== config.wallets.length ||
    config.wallets.some((wallet) => !publicKey.test(wallet))
  ) {
    throw new Error("SOLANA_FOLLOWED_WALLETS must contain 1-100 unique public keys");
  }
  if (!Number.isSafeInteger(config.timeoutMs) || config.timeoutMs <= 0) {
    throw new Error("request timeout must be positive");
  }
  const stateUrl = new URL("/v1/solana-wallet-flow", config.collectorUrl);
  const stateResponse = await fetch(stateUrl, {
    headers: { accept: "application/json" },
    signal: AbortSignal.timeout(config.timeoutMs),
  });
  if (!stateResponse.ok) throw new Error(`collector state returned ${stateResponse.status}`);
  const durableCursors = cursors(await stateResponse.json());
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
  const result: PollResult = { acquisitions: 0, checkpoints: 0, gaps: 0 };

  for (const [index, wallet] of config.wallets.entries()) {
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
    }
    await post(config.collectorUrl, config.hmacSecret, config.timeoutMs, capture.checkpoint);
    result.checkpoints += 1;
    if (capture.checkpoint.payload.status === "gap") result.gaps += 1;
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
  const wallets = (process.env.SOLANA_FOLLOWED_WALLETS ?? "")
    .split(",")
    .map((wallet) => wallet.trim())
    .filter(Boolean);
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
  let stopping = false;
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => { stopping = true; });
  }
  while (!stopping) {
    try {
      const result = await pollSolanaWalletFlow({
        wallets,
        collectorUrl,
        rpcUrl,
        hmacSecret,
        sessionId,
        timeoutMs,
        observedAtMs: BigInt(Date.now()),
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
