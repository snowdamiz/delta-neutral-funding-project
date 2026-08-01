import { createHash } from "node:crypto";

export type SolanaRpc = (method: string, params: unknown[]) => Promise<unknown>;

export type SolanaWalletCursor = {
  signature: string;
  slot: number;
};

type Envelope<T extends string, P> = {
  schemaVersion: 1;
  eventId: string;
  eventType: T;
  source: string;
  observedAtMs: string;
  sourceSlot: string;
  sourceSequence: string;
  idempotencyKey: string;
  rawPayloadHash: string;
  payload: P;
};

export type SolanaWalletAcquisitionEvent = Envelope<
  "SolanaWalletAcquisition",
  {
    wallet: string;
    signature: string;
    confirmedAtMs: string;
    inputMint: string;
    inputAmountAtoms: string;
    outputMint: string;
    outputAmountAtoms: string;
    outputDecimals: string;
    routePrograms: string[];
  }
>;

export type SolanaWalletCheckpointEvent = Envelope<
  "SolanaWalletCheckpoint",
  {
    wallet: string;
    status: "complete" | "gap";
    reason: "backfill_complete" | "cursor_not_recovered" | "backfill_limit_reached";
    previousSignature: string;
    previousSlot: string;
    latestSignature: string;
    latestSlot: string;
  }
>;

export type SolanaWalletCapture = {
  acquisitions: SolanaWalletAcquisitionEvent[];
  checkpoint: SolanaWalletCheckpointEvent;
};

type SignatureRow = {
  signature: string;
  slot: number;
  err: unknown;
  confirmationStatus: "confirmed" | "finalized";
  blockTime: number;
};

type TokenBalance = {
  mint: string;
  owner?: string;
  uiTokenAmount: { amount: string; decimals: number };
};

const publicKey = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const unsigned = /^(0|[1-9][0-9]*)$/;
const wrappedSol = "So11111111111111111111111111111111111111112";
const ordinaryPrograms = new Set([
  "11111111111111111111111111111111",
  "ComputeBudget111111111111111111111111111111",
  "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
  "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
  "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL",
]);

function object(value: unknown, field: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${field} must be an object`);
  }
  return value as Record<string, unknown>;
}

function array(value: unknown, field: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${field} must be an array`);
  return value;
}

function string(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${field} must be a non-empty string`);
  }
  return value;
}

function safeInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new Error(`${field} must be a non-negative safe integer`);
  }
  return value;
}

function hash(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function signatureRow(value: unknown, index: number): SignatureRow {
  const row = object(value, `signatures[${index}]`);
  const confirmationStatus = string(row.confirmationStatus, "confirmationStatus");
  if (confirmationStatus !== "confirmed" && confirmationStatus !== "finalized") {
    throw new Error("wallet signatures must be confirmed");
  }
  return {
    signature: string(row.signature, "signature"),
    slot: safeInteger(row.slot, "slot"),
    err: row.err,
    confirmationStatus,
    blockTime: safeInteger(row.blockTime, "blockTime"),
  };
}

function accountKey(value: unknown): string {
  return typeof value === "string"
    ? value
    : string(object(value, "account key").pubkey, "account key pubkey");
}

function tokenBalances(value: unknown, wallet: string, field: string): Map<string, {
  amount: bigint;
  decimals: number;
}> {
  const result = new Map<string, { amount: bigint; decimals: number }>();
  for (const [index, raw] of array(value ?? [], field).entries()) {
    const balance = object(raw, `${field}[${index}]`) as unknown as TokenBalance;
    if (balance.owner !== wallet) continue;
    const mint = string(balance.mint, `${field}[${index}].mint`);
    const ui = object(balance.uiTokenAmount, `${field}[${index}].uiTokenAmount`);
    const amount = string(ui.amount, `${field}[${index}].amount`);
    if (!unsigned.test(amount)) throw new Error(`${field}[${index}].amount is invalid`);
    const decimals = safeInteger(ui.decimals, `${field}[${index}].decimals`);
    const prior = result.get(mint);
    if (prior && prior.decimals !== decimals) throw new Error(`${mint} decimals changed`);
    result.set(mint, { amount: (prior?.amount ?? 0n) + BigInt(amount), decimals });
  }
  return result;
}

function programIds(transaction: Record<string, unknown>): string[] {
  const message = object(object(transaction.transaction, "transaction").message, "message");
  const meta = object(transaction.meta, "meta");
  const ids: string[] = [];
  const add = (instruction: unknown) => {
    const id = object(instruction, "instruction").programId;
    if (typeof id === "string" && !ids.includes(id)) ids.push(id);
  };
  for (const instruction of array(message.instructions, "instructions")) add(instruction);
  for (const group of array(meta.innerInstructions ?? [], "innerInstructions")) {
    for (const instruction of array(object(group, "inner instruction group").instructions, "inner instructions")) {
      add(instruction);
    }
  }
  return ids;
}

function acquisitions(
  row: SignatureRow,
  rawTransaction: unknown,
  wallet: string,
  observedAtMs: bigint,
  sessionId: string,
): SolanaWalletAcquisitionEvent[] {
  const transaction = object(rawTransaction, "transaction result");
  const meta = object(transaction.meta, "transaction meta");
  if (meta.err !== null && meta.err !== undefined) return [];
  const message = object(object(transaction.transaction, "transaction").message, "message");
  const keys = array(message.accountKeys, "accountKeys").map(accountKey);
  const walletIndex = keys.indexOf(wallet);
  if (walletIndex < 0) throw new Error("followed wallet is absent from its transaction");
  const programs = programIds(transaction);
  const logs = array(meta.logMessages ?? [], "logMessages").map((value) => string(value, "log message"));
  const swap = programs.some((id) => !ordinaryPrograms.has(id)) || logs.some((line) => /(?:swap|route|buy)/i.test(line));
  if (!swap) return [];

  const pre = tokenBalances(meta.preTokenBalances, wallet, "preTokenBalances");
  const post = tokenBalances(meta.postTokenBalances, wallet, "postTokenBalances");
  const mints = new Set([...pre.keys(), ...post.keys()]);
  const deltas = [...mints].map((mint) => ({
    mint,
    decimals: post.get(mint)?.decimals ?? pre.get(mint)?.decimals ?? 0,
    amount: (post.get(mint)?.amount ?? 0n) - (pre.get(mint)?.amount ?? 0n),
  }));
  const tokenInput = deltas.filter(({ amount }) => amount < 0n).sort((left, right) =>
    left.mint.localeCompare(right.mint)
  )[0];
  const preBalances = array(meta.preBalances, "preBalances");
  const postBalances = array(meta.postBalances, "postBalances");
  const lamportsSpent = BigInt(safeInteger(preBalances[walletIndex], "pre wallet lamports"))
    - BigInt(safeInteger(postBalances[walletIndex], "post wallet lamports"));
  if (!tokenInput && lamportsSpent <= 0n) return [];
  const inputMint = tokenInput?.mint ?? wrappedSol;
  const inputAmount = tokenInput ? -tokenInput.amount : lamportsSpent;
  const raw = JSON.stringify(rawTransaction);

  return deltas
    .filter(({ amount, mint }) => amount > 0n && mint !== inputMint)
    .sort((left, right) => left.mint.localeCompare(right.mint))
    .map(({ mint, amount, decimals }) => ({
      schemaVersion: 1,
      eventId: `${sessionId}:solana-acquisition:${row.signature}:${mint}`,
      eventType: "SolanaWalletAcquisition",
      source: `solana-wallet:${wallet}:${mint}`,
      observedAtMs: observedAtMs.toString(),
      sourceSlot: row.slot.toString(),
      sourceSequence: row.signature,
      idempotencyKey: `solana-acquisition:${wallet}:${row.signature}:${mint}`,
      rawPayloadHash: hash(raw),
      payload: {
        wallet,
        signature: row.signature,
        confirmedAtMs: String(row.blockTime * 1000),
        inputMint,
        inputAmountAtoms: inputAmount.toString(),
        outputMint: mint,
        outputAmountAtoms: amount.toString(),
        outputDecimals: String(decimals),
        routePrograms: programs,
      },
    }));
}

export async function captureSolanaWalletFlow(input: {
  wallet: string;
  cursor?: SolanaWalletCursor;
  observedAtMs: bigint;
  sessionId: string;
  rpc: SolanaRpc;
  pageSize?: number;
  maxPages?: number;
}): Promise<SolanaWalletCapture> {
  if (!publicKey.test(input.wallet)) throw new Error("wallet must be a Solana public key");
  if (input.observedAtMs < 0n || input.sessionId.length === 0) {
    throw new Error("capture identity is invalid");
  }
  const pageSize = input.pageSize ?? 1000;
  const maxPages = input.maxPages ?? 10;
  if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 1000 || !Number.isInteger(maxPages) || maxPages < 1) {
    throw new Error("backfill bounds are invalid");
  }

  // No durable cursor yet: establish a baseline at the newest signature
  // instead of paging a wallet's whole history. Nothing before the moment a
  // wallet is followed is tradeable, and a wallet with more history than the
  // page budget would otherwise latch gapped forever — which is every real
  // trader. A baseline is identifiable in the evidence by its empty previous
  // signature.
  if (!input.cursor) {
    const values = array(
      await input.rpc("getSignaturesForAddress", [input.wallet, {
        commitment: "confirmed",
        limit: 1,
      }]),
      "signature history",
    ).map(signatureRow);
    const baseline = values[0];
    const baselinePayload: SolanaWalletCheckpointEvent["payload"] = {
      wallet: input.wallet,
      status: "complete",
      reason: "backfill_complete",
      previousSignature: "",
      previousSlot: "0",
      latestSignature: baseline?.signature ?? "",
      latestSlot: String(baseline?.slot ?? 0),
    };
    return {
      acquisitions: [],
      checkpoint: {
        schemaVersion: 1,
        eventId: `${input.sessionId}:solana-checkpoint:${input.wallet}:${input.observedAtMs}`,
        eventType: "SolanaWalletCheckpoint",
        source: `solana-wallet:${input.wallet}`,
        observedAtMs: input.observedAtMs.toString(),
        sourceSlot: baselinePayload.latestSlot,
        sourceSequence: baselinePayload.latestSignature || input.observedAtMs.toString(),
        idempotencyKey: `${input.sessionId}:solana-checkpoint:${input.wallet}:${input.observedAtMs}`,
        rawPayloadHash: hash(JSON.stringify(baselinePayload)),
        payload: baselinePayload,
      },
    };
  }

  const rows: SignatureRow[] = [];
  let before: string | undefined;
  let exhausted = false;
  for (let page = 0; page < maxPages; page += 1) {
    const options: Record<string, unknown> = {
      commitment: "confirmed",
      limit: pageSize,
    };
    if (before) options.before = before;
    if (input.cursor) options.until = input.cursor.signature;
    const values = array(
      await input.rpc("getSignaturesForAddress", [input.wallet, options]),
      "signature history",
    ).map(signatureRow);
    rows.push(...values);
    if (values.length < pageSize) {
      exhausted = true;
      break;
    }
    before = values.at(-1)?.signature;
  }

  let cursorAvailable = true;
  if (input.cursor) {
    const statuses = object(
      await input.rpc("getSignatureStatuses", [[input.cursor.signature], { searchTransactionHistory: true }]),
      "signature statuses",
    );
    const status = array(statuses.value, "signature statuses value")[0];
    cursorAvailable = status !== null && status !== undefined;
  }
  const crossedCursor = input.cursor
    ? rows.some(({ slot }) => slot < input.cursor!.slot)
    : false;
  const status: "complete" | "gap" = exhausted && cursorAvailable && !crossedCursor
    ? "complete"
    : "gap";
  const reason = status === "complete"
    ? "backfill_complete"
    : !cursorAvailable || crossedCursor
      ? "cursor_not_recovered"
      : "backfill_limit_reached";
  const latest = rows[0];
  const checkpointPayload: SolanaWalletCheckpointEvent["payload"] = {
    wallet: input.wallet,
    status,
    reason,
    previousSignature: input.cursor?.signature ?? "",
    previousSlot: String(input.cursor?.slot ?? 0),
    latestSignature: latest?.signature ?? input.cursor?.signature ?? "",
    latestSlot: String(latest?.slot ?? input.cursor?.slot ?? 0),
  };
  const checkpoint: SolanaWalletCheckpointEvent = {
    schemaVersion: 1,
    eventId: `${input.sessionId}:solana-checkpoint:${input.wallet}:${input.observedAtMs}`,
    eventType: "SolanaWalletCheckpoint",
    source: `solana-wallet:${input.wallet}`,
    observedAtMs: input.observedAtMs.toString(),
    sourceSlot: checkpointPayload.latestSlot,
    sourceSequence: checkpointPayload.latestSignature || input.observedAtMs.toString(),
    idempotencyKey: `${input.sessionId}:solana-checkpoint:${input.wallet}:${input.observedAtMs}`,
    rawPayloadHash: hash(JSON.stringify(checkpointPayload)),
    payload: checkpointPayload,
  };
  if (status === "gap") return { acquisitions: [], checkpoint };

  const captured: SolanaWalletAcquisitionEvent[] = [];
  for (const row of [...rows].reverse()) {
    if (row.err !== null && row.err !== undefined) continue;
    const transaction = await input.rpc("getTransaction", [row.signature, {
      commitment: "confirmed",
      encoding: "jsonParsed",
      maxSupportedTransactionVersion: 0,
    }]);
    if (transaction !== null) {
      captured.push(...acquisitions(row, transaction, input.wallet, input.observedAtMs, input.sessionId));
    }
  }
  return { acquisitions: captured, checkpoint };
}
