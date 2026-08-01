import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";

// The live executor is the only component that can move real funds. It holds
// the only signing key, claims DB-capped intents from the collector, executes
// them through Jupiter, and reports authoritative fills back. It never
// decides anything: sizing, caps, and eligibility were already enforced when
// the intent was created, and the executor re-enforces slippage and expiry.

export type LiveIntent = {
  intentId: string;
  kind: "ENTRY" | "EXIT";
  mint: string;
  inputUsdMicros: bigint;
  fractionBps: number;
  maxSlippageBps: number;
  liveRemainingAtoms: bigint;
  expiresAtMs: bigint;
};

export type LiveReport = {
  intentId: string;
  status: "filled" | "failed";
  resolvedAtMs: string;
  signature?: string;
  inputAmount?: string;
  outputAmount?: string;
  feeLamports?: string;
  slot?: string;
  failureReason?: string;
};

export type RawQuote = {
  body: Record<string, unknown>;
  inAmount: bigint;
  outAmount: bigint;
};

export type LiveDeps = {
  quote: (
    inputMint: string,
    outputMint: string,
    amount: bigint,
    slippageBps: number,
  ) => Promise<RawQuote>;
  swap: (
    quoteBody: Record<string, unknown>,
    userPublicKey: string,
  ) => Promise<{ swapTransaction: string; lastValidBlockHeight: bigint }>;
  rpc: (method: string, params: unknown[]) => Promise<unknown>;
  signer: LiveSigner;
  nowMs: () => bigint;
  sleepMs: (ms: number) => Promise<void>;
  confirmTimeoutMs: number;
};

export type LiveSigner = {
  publicKeyBase58: string;
  publicKeyBytes: Buffer;
  privateKey: KeyObject;
};

const usdc = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const base58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const pkcs8Ed25519Prefix = Buffer.from("302e020100300506032b657004220420", "hex");

export function base58Encode(bytes: Buffer): string {
  let value = 0n;
  for (const byte of bytes) value = value * 256n + BigInt(byte);
  let encoded = "";
  while (value > 0n) {
    encoded = base58Alphabet[Number(value % 58n)] + encoded;
    value /= 58n;
  }
  for (const byte of bytes) {
    if (byte !== 0) break;
    encoded = "1" + encoded;
  }
  return encoded;
}

export function loadLiveSigner(path: string): LiveSigner {
  const raw = JSON.parse(readFileSync(path, "utf8")) as unknown;
  if (!Array.isArray(raw) || raw.length !== 64
    || raw.some((byte) => typeof byte !== "number" || byte < 0 || byte > 255)) {
    throw new Error("signer keypair must be a 64-byte JSON array");
  }
  const bytes = Buffer.from(raw as number[]);
  const seed = bytes.subarray(0, 32);
  const publicKeyBytes = Buffer.from(bytes.subarray(32, 64));
  return {
    publicKeyBase58: base58Encode(publicKeyBytes),
    publicKeyBytes,
    privateKey: createPrivateKey({
      key: Buffer.concat([pkcs8Ed25519Prefix, seed]),
      format: "der",
      type: "pkcs8",
    }),
  };
}

// Wire format: compact-u16 signature count, 64-byte signatures, message.
// Only single-signer transactions are accepted, and the message's fee payer
// must be the executor's own key — this process never co-signs anything.
export function signTransaction(base64Transaction: string, signer: LiveSigner): string {
  const wire = Buffer.from(base64Transaction, "base64");
  if (wire.length < 1 + 64 + 4 || wire[0] !== 1) {
    throw new Error("live transaction must have exactly one signer");
  }
  const message = wire.subarray(1 + 64);
  let offset = (message[0]! & 0x80) !== 0 ? 1 : 0;
  offset += 3;
  const keyCount = message[offset]!;
  if ((keyCount & 0x80) !== 0 || keyCount === 0) {
    throw new Error("live transaction account keys are malformed");
  }
  offset += 1;
  const feePayer = message.subarray(offset, offset + 32);
  if (!feePayer.equals(signer.publicKeyBytes)) {
    throw new Error("live transaction fee payer is not the executor key");
  }
  const signature = sign(null, message, signer.privateKey);
  signature.copy(wire, 1);
  return wire.toString("base64");
}

function record(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function tokenDelta(meta: Record<string, unknown>, owner: string, mint: string): bigint {
  let delta = 0n;
  for (const [signMultiplier, field] of [[-1n, "preTokenBalances"], [1n, "postTokenBalances"]] as const) {
    const balances = meta[field];
    if (!Array.isArray(balances)) continue;
    for (const raw of balances) {
      const balance = record(raw, field);
      if (balance.mint !== mint || balance.owner !== owner) continue;
      const amount = record(balance.uiTokenAmount, "uiTokenAmount").amount;
      if (typeof amount !== "string" || !/^(0|[1-9][0-9]*)$/.test(amount)) {
        throw new Error("transaction token balance is malformed");
      }
      delta += signMultiplier * BigInt(amount);
    }
  }
  return delta;
}

async function confirmSignature(
  deps: LiveDeps,
  signature: string,
  lastValidBlockHeight: bigint,
): Promise<Record<string, unknown>> {
  const startedAt = deps.nowMs();
  for (;;) {
    const statuses = record(
      await deps.rpc("getSignatureStatuses", [[signature], { searchTransactionHistory: true }]),
      "signature statuses",
    );
    const status = Array.isArray(statuses.value) ? statuses.value[0] : null;
    if (status !== null && status !== undefined) {
      const parsed = record(status, "signature status");
      if (parsed.err !== null && parsed.err !== undefined) {
        throw new Error(`TRANSACTION_FAILED:${JSON.stringify(parsed.err)}`);
      }
      if (parsed.confirmationStatus === "confirmed" || parsed.confirmationStatus === "finalized") {
        const transaction = record(
          await deps.rpc("getTransaction", [signature, {
            commitment: "confirmed",
            encoding: "jsonParsed",
            maxSupportedTransactionVersion: 0,
          }]),
          "confirmed transaction",
        );
        return record(transaction.meta, "confirmed transaction meta");
      }
    } else {
      const blockHeight = await deps.rpc("getBlockHeight", [{ commitment: "confirmed" }]);
      if (typeof blockHeight === "number" && BigInt(blockHeight) > lastValidBlockHeight) {
        throw new Error("BLOCKHASH_EXPIRED");
      }
    }
    if (deps.nowMs() - startedAt > BigInt(deps.confirmTimeoutMs)) {
      throw new Error(`CONFIRMATION_TIMEOUT:${signature}`);
    }
    await deps.sleepMs(1000);
  }
}

export async function executeLiveIntent(
  intent: LiveIntent,
  deps: LiveDeps,
): Promise<LiveReport> {
  const failed = (reason: string): LiveReport => ({
    intentId: intent.intentId,
    status: "failed",
    failureReason: reason.slice(0, 500),
    resolvedAtMs: deps.nowMs().toString(),
  });
  try {
    if (deps.nowMs() >= intent.expiresAtMs) {
      return failed("INTENT_EXPIRED");
    }
    let inputMint: string;
    let outputMint: string;
    let amount: bigint;
    if (intent.kind === "ENTRY") {
      inputMint = usdc;
      outputMint = intent.mint;
      amount = intent.inputUsdMicros;
    } else {
      inputMint = intent.mint;
      outputMint = usdc;
      amount = intent.fractionBps === 10000
        ? intent.liveRemainingAtoms
        : intent.liveRemainingAtoms * BigInt(intent.fractionBps) / 10000n;
      if (amount <= 0n) return failed("NO_LIVE_POSITION");
    }
    const quote = await deps.quote(inputMint, outputMint, amount, intent.maxSlippageBps);
    const swap = await deps.swap(quote.body, deps.signer.publicKeyBase58);
    const signed = signTransaction(swap.swapTransaction, deps.signer);
    const signature = await deps.rpc("sendTransaction", [signed, {
      encoding: "base64",
      skipPreflight: false,
      preflightCommitment: "confirmed",
      maxRetries: 3,
    }]);
    if (typeof signature !== "string" || signature.length === 0) {
      return failed("SEND_REJECTED");
    }
    const meta = await confirmSignature(deps, signature, swap.lastValidBlockHeight);
    const fee = meta.fee;
    if (typeof fee !== "number" || fee < 0) {
      return failed(`FEE_UNREADABLE:${signature}`);
    }
    const outputDelta = tokenDelta(meta, deps.signer.publicKeyBase58, outputMint);
    return {
      intentId: intent.intentId,
      status: "filled",
      signature,
      inputAmount: quote.inAmount.toString(),
      outputAmount: (outputDelta > 0n ? outputDelta : 0n).toString(),
      feeLamports: String(fee),
      slot: typeof meta.slot === "number" ? String(meta.slot) : "0",
      resolvedAtMs: deps.nowMs().toString(),
    };
  } catch (error) {
    return failed(error instanceof Error ? error.message : String(error));
  }
}

export function parseClaimedIntents(value: unknown): LiveIntent[] {
  if (!Array.isArray(value)) {
    throw new Error("collector returned invalid live intents");
  }
  return value.map((raw) => {
    const item = record(raw, "live intent");
    if (
      typeof item.intentId !== "string" || item.intentId.length === 0
      || (item.kind !== "ENTRY" && item.kind !== "EXIT")
      || typeof item.mint !== "string"
      || !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(item.mint)
      || typeof item.inputUsdMicros !== "string"
      || !/^(0|[1-9][0-9]*)$/.test(item.inputUsdMicros)
      || typeof item.fractionBps !== "number"
      || item.fractionBps < 0 || item.fractionBps > 10000
      || typeof item.maxSlippageBps !== "number"
      || item.maxSlippageBps < 1 || item.maxSlippageBps > 10000
      || typeof item.liveRemainingAtoms !== "string"
      || !/^(0|[1-9][0-9]*)$/.test(item.liveRemainingAtoms)
      || typeof item.expiresAtMs !== "string"
      || !/^(0|[1-9][0-9]*)$/.test(item.expiresAtMs)
    ) {
      throw new Error("collector returned an invalid live intent");
    }
    return {
      intentId: item.intentId,
      kind: item.kind,
      mint: item.mint,
      inputUsdMicros: BigInt(item.inputUsdMicros),
      fractionBps: item.fractionBps,
      maxSlippageBps: item.maxSlippageBps,
      liveRemainingAtoms: BigInt(item.liveRemainingAtoms),
      expiresAtMs: BigInt(item.expiresAtMs),
    };
  });
}
