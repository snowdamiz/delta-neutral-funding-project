import { pathToFileURL } from "node:url";
import {
  executeLiveIntent,
  loadLiveSigner,
  parseClaimedIntents,
  type LiveDeps,
  type RawQuote,
} from "./solana-live-executor.js";
import { signBody } from "./transport.js";

function positiveInteger(value: string | undefined, fallback: number, name: string): number {
  const parsed = Number(value ?? fallback);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

function object(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function integerText(value: unknown, field: string): bigint {
  const raw = typeof value === "number" ? String(value) : value;
  if (typeof raw !== "string" || !/^(0|[1-9][0-9]*)$/.test(raw)) {
    throw new Error(`${field} must be an unsigned integer`);
  }
  return BigInt(raw);
}

function createRawJupiterQuote(
  endpoint: string,
  apiKey: string,
  timeoutMs: number,
): LiveDeps["quote"] {
  return async (inputMint, outputMint, amount, slippageBps) => {
    const url = new URL(`${endpoint.replace(/\/$/, "")}/quote`);
    url.searchParams.set("inputMint", inputMint);
    url.searchParams.set("outputMint", outputMint);
    url.searchParams.set("amount", amount.toString());
    url.searchParams.set("swapMode", "ExactIn");
    url.searchParams.set("slippageBps", String(slippageBps));
    const response = await fetch(url, {
      headers: apiKey ? { "x-api-key": apiKey } : {},
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) throw new Error(`Jupiter quote returned ${response.status}`);
    const body = object(await response.json(), "Jupiter quote");
    if (body.inputMint !== inputMint || body.outputMint !== outputMint) {
      throw new Error("Jupiter quote identity mismatch");
    }
    return {
      body,
      inAmount: integerText(body.inAmount, "Jupiter inAmount"),
      outAmount: integerText(body.outAmount, "Jupiter outAmount"),
    } satisfies RawQuote;
  };
}

function createJupiterSwap(
  endpoint: string,
  apiKey: string,
  timeoutMs: number,
): LiveDeps["swap"] {
  return async (quoteBody, userPublicKey) => {
    const response = await fetch(`${endpoint.replace(/\/$/, "")}/swap`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(apiKey ? { "x-api-key": apiKey } : {}),
      },
      body: JSON.stringify({
        quoteResponse: quoteBody,
        userPublicKey,
        wrapAndUnwrapSol: true,
        dynamicComputeUnitLimit: true,
        prioritizationFeeLamports: "auto",
      }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) throw new Error(`Jupiter swap returned ${response.status}`);
    const body = object(await response.json(), "Jupiter swap");
    if (typeof body.swapTransaction !== "string" || body.swapTransaction.length === 0) {
      throw new Error("Jupiter swap returned no transaction");
    }
    return {
      swapTransaction: body.swapTransaction,
      lastValidBlockHeight: integerText(
        body.lastValidBlockHeight,
        "Jupiter lastValidBlockHeight",
      ),
    };
  };
}

async function signedPost(
  url: string,
  hmacSecret: string,
  timeoutMs: number,
  payload: unknown,
): Promise<unknown> {
  const body = JSON.stringify(payload);
  const response = await fetch(url, {
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
  return response.json();
}

async function main(): Promise<void> {
  const collectorUrl = (process.env.COLLECTOR_URL ?? "http://127.0.0.1:8080/v1/events")
    .replace(/\/v1\/events$/, "");
  const rpcUrl = process.env.SOLANA_RPC_URL ?? "https://api.mainnet-beta.solana.com";
  const hmacSecret = process.env.ADAPTER_HMAC_SECRET ?? "";
  const executorId = process.env.LIVE_EXECUTOR_ID ?? "solana-live-executor";
  const keypairPath = process.env.SOLANA_SIGNER_KEYPAIR ?? "";
  const timeoutMs = positiveInteger(process.env.REQUEST_TIMEOUT_MS, 30_000, "REQUEST_TIMEOUT_MS");
  const intervalMs = positiveInteger(
    process.env.LIVE_POLL_INTERVAL_MS,
    2_000,
    "LIVE_POLL_INTERVAL_MS",
  );
  if (keypairPath.length === 0) {
    throw new Error("SOLANA_SIGNER_KEYPAIR is required: the executor refuses to start without a key");
  }
  const signer = loadLiveSigner(keypairPath);
  console.log(JSON.stringify({
    timestampMs: Date.now(),
    event: "live_executor_started",
    executorId,
    publicKey: signer.publicKeyBase58,
  }));
  let rpcId = 0;
  const deps: LiveDeps = {
    quote: createRawJupiterQuote(
      process.env.JUPITER_URL ?? "https://api.jup.ag/swap/v1",
      process.env.JUPITER_API_KEY ?? "",
      timeoutMs,
    ),
    swap: createJupiterSwap(
      process.env.JUPITER_URL ?? "https://api.jup.ag/swap/v1",
      process.env.JUPITER_API_KEY ?? "",
      timeoutMs,
    ),
    rpc: async (method, params) => {
      const response = await fetch(rpcUrl, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
        signal: AbortSignal.timeout(timeoutMs),
      });
      if (!response.ok) throw new Error(`Solana RPC returned ${response.status}`);
      const body = object(await response.json(), "Solana RPC response");
      if (body.error !== undefined) {
        throw new Error(`Solana RPC ${method} failed: ${JSON.stringify(body.error)}`);
      }
      return body.result;
    },
    signer,
    nowMs: () => BigInt(Date.now()),
    sleepMs: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    confirmTimeoutMs: positiveInteger(
      process.env.LIVE_CONFIRM_TIMEOUT_MS,
      90_000,
      "LIVE_CONFIRM_TIMEOUT_MS",
    ),
  };

  let stopping = false;
  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => { stopping = true; });
  }
  while (!stopping) {
    try {
      const claimed = await signedPost(
        `${collectorUrl}/v1/solana-live/claim`,
        hmacSecret,
        timeoutMs,
        { executorId, nowMs: Date.now().toString(), limit: "5" },
      );
      for (const intent of parseClaimedIntents(claimed)) {
        const report = await executeLiveIntent(intent, deps);
        await signedPost(
          `${collectorUrl}/v1/solana-live/reports`,
          hmacSecret,
          timeoutMs,
          report,
        );
        console.log(JSON.stringify({
          timestampMs: Date.now(),
          event: "live_intent_resolved",
          intentId: intent.intentId,
          kind: intent.kind,
          status: report.status,
          ...(report.signature === undefined ? {} : { signature: report.signature }),
          ...(report.failureReason === undefined ? {} : { reason: report.failureReason }),
        }));
      }
    } catch (error) {
      console.error(JSON.stringify({
        timestampMs: Date.now(),
        event: "live_executor_poll_failed",
        reason: error instanceof Error ? error.message : String(error),
      }));
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
