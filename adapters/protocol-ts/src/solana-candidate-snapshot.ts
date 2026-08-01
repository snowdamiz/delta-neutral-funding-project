import { createHash } from "node:crypto";
import type {
  SolanaRpc,
  SolanaWalletAcquisitionEvent,
} from "./solana-wallet-flow.js";

export type JupiterQuoteResult = {
  inputMint: string;
  outputMint: string;
  inAmount: bigint;
  outAmount: bigint;
  priceImpactBps: number;
  contextSlot: bigint;
  routeLabels: string[];
};

export type JupiterQuote = (
  inputMint: string,
  outputMint: string,
  amount: bigint,
) => Promise<JupiterQuoteResult>;

/** One JSON-RPC request carrying many calls. Optional: without it the flow
 *  scan falls back to bounded-parallel single calls. */
export type SolanaBatchRpc = (
  calls: { method: string; params: unknown[] }[],
) => Promise<unknown[]>;

const FLOW_CONCURRENCY = 8;

async function fetchFlowTransactions(
  signatures: string[],
  rpc: SolanaRpc,
  batchRpc: SolanaBatchRpc | undefined,
): Promise<Map<string, unknown>> {
  const params = (signature: string) => [signature, {
    commitment: "confirmed",
    encoding: "jsonParsed",
    maxSupportedTransactionVersion: 0,
  }];
  const found = new Map<string, unknown>();
  if (batchRpc) {
    // The mint's recent history is the snapshot's dominant cost; one round
    // trip for all of it instead of one per signature.
    for (let start = 0; start < signatures.length; start += 25) {
      const chunk = signatures.slice(start, start + 25);
      const results = await batchRpc(
        chunk.map((signature) => ({ method: "getTransaction", params: params(signature) })),
      );
      chunk.forEach((signature, index) => found.set(signature, results[index]));
    }
    return found;
  }
  for (let start = 0; start < signatures.length; start += FLOW_CONCURRENCY) {
    const chunk = signatures.slice(start, start + FLOW_CONCURRENCY);
    const results = await Promise.all(
      chunk.map((signature) => rpc("getTransaction", params(signature))),
    );
    chunk.forEach((signature, index) => found.set(signature, results[index]));
  }
  return found;
}

type SnapshotPayload = {
  acquisitionEventId: string;
  wallet: string;
  signature: string;
  mint: string;
  snapshotStatus: "complete" | "rejected";
  rejectReason: string;
  sourceObservedAtMs: string;
  tokenProgram: "spl-token" | "token-2022" | "unknown";
  tokenExtensions: string[];
  mintAuthorityDisabled: boolean;
  freezeAuthorityDisabled: boolean;
  transferFeeBps: string;
  transferFeeMaximumAtoms: string;
  transferFeeBuyAtoms: string;
  transferFeeSellAtoms: string;
  supplyAtoms: string;
  decimals: string;
  marketCapUsdMicros: string;
  topTenHolderConcentrationBps: string;
  creator: string;
  creatorInventoryAtoms: string;
  clusterInventoryAtoms: string;
  marketAgeSlots: string;
  migrationStatus: "pre_migration" | "post_migration" | "not_applicable" | "unknown";
  routeLabels: string[];
  buyInputUsdMicros: string;
  buyOutputAtoms: string;
  sellOutputUsdMicros: string;
  entryPriceImpactBps: string;
  roundTripLossBps: string;
  exitDepthUsdMicros: string;
  exitDepthImpactBps: string;
  quoteContextSlot: string;
  paperPositionAtoms: string;
  positionTransferFeeAtoms: string;
  positionSellInputAtoms: string;
  positionSellOutputUsdMicros: string;
  positionSellImpactBps: string;
  flowCoverageComplete: boolean;
  unlinkedBuyerCount: string;
  unlinkedBuyerCount1m: string;
  unlinkedBuyerCount5m: string;
  unlinkedBuyerCount1h: string;
  netQuoteInflowUsdMicros: string;
  netQuoteInflowUsdMicros1m: string;
  netQuoteInflowUsdMicros1h: string;
  volumeUsdMicros1m: string;
  volumeUsdMicros5m: string;
  volumeUsdMicros1h: string;
  creatorSold: boolean;
  clusterSold: boolean;
  sanctionsHit: boolean;
  flowBuyers: Array<{ owner: string; firstSeenMs: string; boughtAtoms: string }>;
};

export type SolanaCandidateSnapshotEvent = {
  schemaVersion: 1;
  eventId: string;
  eventType: "SolanaCandidateSnapshot";
  source: string;
  observedAtMs: string;
  sourceSlot: string;
  sourceSequence: string;
  idempotencyKey: string;
  rawPayloadHash: string;
  payload: SnapshotPayload;
};

const usdc = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const splToken = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const token2022 = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";
const knownExtensions = new Set([
  "transferFeeConfig",
  "metadataPointer",
  "tokenMetadata",
  "groupPointer",
  "tokenGroup",
  "groupMemberPointer",
  "tokenGroupMember",
  "mintCloseAuthority",
]);
const dangerousExtensions = new Map([
  ["permanentDelegate", "TOKEN2022_PERMANENT_DELEGATE"],
  ["defaultAccountState", "TOKEN2022_DEFAULT_ACCOUNT_STATE"],
  ["nonTransferable", "TOKEN2022_NON_TRANSFERABLE"],
  ["confidentialTransferMint", "TOKEN2022_CONFIDENTIAL_TRANSFER"],
  ["transferHook", "TOKEN2022_TRANSFER_HOOK"],
  ["confidentialTransferFeeConfig", "TOKEN2022_CONFIDENTIAL_TRANSFER_FEE"],
  ["confidentialMintBurn", "TOKEN2022_CONFIDENTIAL_MINT_BURN"],
  ["interestBearingConfig", "TOKEN2022_INTEREST_BEARING"],
  ["scaledUiAmount", "TOKEN2022_SCALED_UI_AMOUNT"],
  ["pausable", "TOKEN2022_PAUSABLE"],
  ["permissionedBurn", "TOKEN2022_PERMISSIONED_BURN"],
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

function text(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${field} must be a non-empty string`);
  }
  return value;
}

function integer(value: unknown, field: string): bigint {
  const raw = typeof value === "number" ? String(value) : value;
  if (typeof raw !== "string" || !/^(0|[1-9][0-9]*)$/.test(raw)) {
    throw new Error(`${field} must be an unsigned integer`);
  }
  return BigInt(raw);
}

function impactBps(value: unknown): number {
  const raw = text(value, "priceImpactPct");
  const match = /^(0|[1-9][0-9]*)(?:\.([0-9]+))?$/.exec(raw);
  if (!match) throw new Error("priceImpactPct must be a decimal");
  const fraction = (match[2] ?? "").slice(0, 8).padEnd(8, "0");
  const scaled = BigInt(match[1]!) * 1_000_000_000_000n + BigInt(fraction) * 10_000n;
  return Number((scaled + 99_999_999n) / 100_000_000n);
}

function transferFee(amount: bigint, bps: bigint, maximum: bigint): bigint {
  if (bps === 0n) return 0n;
  const fee = (amount * bps + 9_999n) / 10_000n;
  return fee < maximum ? fee : maximum;
}

function accountKeys(value: unknown): string[] {
  return array(value, "accountKeys").map((key) =>
    typeof key === "string" ? key : text(object(key, "account key").pubkey, "account key pubkey")
  );
}

function defaultPayload(
  acquisition: SolanaWalletAcquisitionEvent,
  observedAtMs: bigint,
  positionUsdMicros: bigint,
): SnapshotPayload {
  return {
    acquisitionEventId: acquisition.eventId,
    wallet: acquisition.payload.wallet,
    signature: acquisition.payload.signature,
    mint: acquisition.payload.outputMint,
    snapshotStatus: "rejected",
    rejectReason: "SNAPSHOT_SOURCE_FAILED",
    sourceObservedAtMs: observedAtMs.toString(),
    tokenProgram: "unknown",
    tokenExtensions: [],
    mintAuthorityDisabled: false,
    freezeAuthorityDisabled: false,
    transferFeeBps: "0",
    transferFeeMaximumAtoms: "0",
    transferFeeBuyAtoms: "0",
    transferFeeSellAtoms: "0",
    supplyAtoms: "0",
    decimals: acquisition.payload.outputDecimals,
    marketCapUsdMicros: "0",
    topTenHolderConcentrationBps: "10000",
    creator: "",
    creatorInventoryAtoms: "0",
    clusterInventoryAtoms: "0",
    marketAgeSlots: "0",
    migrationStatus: "unknown",
    routeLabels: [],
    buyInputUsdMicros: positionUsdMicros.toString(),
    buyOutputAtoms: "0",
    sellOutputUsdMicros: "0",
    entryPriceImpactBps: "10000",
    roundTripLossBps: "10000",
    exitDepthUsdMicros: "0",
    exitDepthImpactBps: "10000",
    quoteContextSlot: "0",
    paperPositionAtoms: "0",
    positionTransferFeeAtoms: "0",
    positionSellInputAtoms: "0",
    positionSellOutputUsdMicros: "0",
    positionSellImpactBps: "10000",
    flowCoverageComplete: false,
    unlinkedBuyerCount: "0",
    unlinkedBuyerCount1m: "0",
    unlinkedBuyerCount5m: "0",
    unlinkedBuyerCount1h: "0",
    netQuoteInflowUsdMicros: "0",
    netQuoteInflowUsdMicros1m: "0",
    netQuoteInflowUsdMicros1h: "0",
    volumeUsdMicros1m: "0",
    volumeUsdMicros5m: "0",
    volumeUsdMicros1h: "0",
    creatorSold: false,
    clusterSold: false,
    sanctionsHit: false,
    flowBuyers: [],
  };
}

function event(
  acquisition: SolanaWalletAcquisitionEvent,
  observedAtMs: bigint,
  sessionId: string,
  payload: SnapshotPayload,
): SolanaCandidateSnapshotEvent {
  const raw = JSON.stringify(payload);
  return {
    schemaVersion: 1,
    eventId: `${sessionId}:solana-snapshot:${acquisition.payload.signature}:${acquisition.payload.outputMint}:${observedAtMs}`,
    eventType: "SolanaCandidateSnapshot",
    source: `solana-candidate:${acquisition.payload.outputMint}`,
    observedAtMs: observedAtMs.toString(),
    sourceSlot: acquisition.sourceSlot,
    sourceSequence: acquisition.payload.signature,
    idempotencyKey: `solana-snapshot:${acquisition.payload.signature}:${acquisition.payload.outputMint}:${observedAtMs}`,
    rawPayloadHash: createHash("sha256").update(raw).digest("hex"),
    payload,
  };
}

function extensionState(value: unknown): { names: string[]; values: Map<string, Record<string, unknown>> } {
  const names: string[] = [];
  const values = new Map<string, Record<string, unknown>>();
  for (const [index, raw] of array(value ?? [], "mint extensions").entries()) {
    const extension = object(raw, `mint extensions[${index}]`);
    const name = text(extension.extension, `mint extensions[${index}].extension`);
    names.push(name);
    values.set(name, object(extension.state ?? {}, `${name} state`));
  }
  return { names, values };
}

function activeTransferFee(
  state: Record<string, unknown> | undefined,
  epoch: bigint,
): { bps: bigint; maximum: bigint } {
  if (!state) return { bps: 0n, maximum: 0n };
  const older = object(state.olderTransferFee, "older transfer fee");
  const newer = object(state.newerTransferFee, "newer transfer fee");
  const active = integer(newer.epoch, "newer transfer fee epoch") <= epoch ? newer : older;
  return {
    bps: integer(active.transferFeeBasisPoints, "transfer fee basis points"),
    maximum: integer(active.maximumFee, "transfer fee maximum"),
  };
}

type FlowWindow = {
  buyers: Set<string>;
  boughtAtoms: bigint;
  soldAtoms: bigint;
};

function tokenOwnerDeltas(transaction: unknown, mint: string): Map<string, bigint> {
  const meta = object(transaction, "flow transaction").meta;
  if (meta === null || meta === undefined) return new Map();
  const parsedMeta = object(meta, "flow transaction meta");
  const deltas = new Map<string, bigint>();
  for (const [sign, field] of [[-1n, "preTokenBalances"], [1n, "postTokenBalances"]] as const) {
    for (const raw of array(parsedMeta[field] ?? [], field)) {
      const balance = object(raw, "token balance");
      if (balance.mint !== mint || typeof balance.owner !== "string") continue;
      const amount = integer(object(balance.uiTokenAmount, "token amount").amount, "token amount atoms");
      deltas.set(balance.owner, (deltas.get(balance.owner) ?? 0n) + sign * amount);
    }
  }
  return deltas;
}

function usdMicros(atoms: bigint, buyUsdMicros: bigint, buyOutputAtoms: bigint): string {
  return (buyOutputAtoms === 0n ? 0n : atoms * buyUsdMicros / buyOutputAtoms).toString();
}

function migrationFrom(routeLabels: string[]): SnapshotPayload["migrationStatus"] {
  return routeLabels.some((label) => /pumpswap/i.test(label))
    ? "post_migration"
    : routeLabels.some((label) => /pump\.fun/i.test(label))
      ? "pre_migration"
      : "not_applicable";
}

export function createJupiterQuote(
  endpoint: string,
  apiKey: string,
  timeoutMs: number,
): JupiterQuote {
  return async (inputMint, outputMint, amount) => {
    const url = new URL(`${endpoint.replace(/\/$/, "")}/quote`);
    url.searchParams.set("inputMint", inputMint);
    url.searchParams.set("outputMint", outputMint);
    url.searchParams.set("amount", amount.toString());
    url.searchParams.set("swapMode", "ExactIn");
    url.searchParams.set("slippageBps", "1000");
    const response = await fetch(url, {
      headers: apiKey ? { "x-api-key": apiKey } : {},
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) throw new Error(`Jupiter quote returned ${response.status}`);
    const body = object(await response.json(), "Jupiter quote");
    if (body.inputMint !== inputMint || body.outputMint !== outputMint) {
      throw new Error("Jupiter quote identity mismatch");
    }
    const routeLabels = array(body.routePlan, "Jupiter route plan").map((raw) =>
      text(object(object(raw, "Jupiter route").swapInfo, "Jupiter swap info").label, "Jupiter route label")
    );
    if (routeLabels.length === 0) throw new Error("Jupiter route is empty");
    return {
      inputMint,
      outputMint,
      inAmount: integer(body.inAmount, "Jupiter inAmount"),
      outAmount: integer(body.outAmount, "Jupiter outAmount"),
      priceImpactBps: impactBps(body.priceImpactPct),
      contextSlot: integer(body.contextSlot, "Jupiter contextSlot"),
      routeLabels,
    };
  };
}

export async function snapshotSolanaCandidate(input: {
  acquisition: SolanaWalletAcquisitionEvent;
  observedAtMs: bigint;
  sessionId: string;
  rpc: SolanaRpc;
  quote: JupiterQuote;
  cohortWallets: string[];
  sanctionedAddresses: Set<string>;
  positionUsdMicros: bigint;
  exitDepthMultiple: bigint;
  batchRpc?: SolanaBatchRpc;
  paperPositionAtoms?: bigint;
}): Promise<SolanaCandidateSnapshotEvent> {
  const buyUsdMicros = input.positionUsdMicros;
  const depthUsdMicros = buyUsdMicros * input.exitDepthMultiple;
  const payload = defaultPayload(input.acquisition, input.observedAtMs, buyUsdMicros);
  const mint = input.acquisition.payload.outputMint;
  let rejectReason = "";
  try {
    const [mintResponse, holdersResponse, transactionResponse, historyResponse] = await Promise.all([
      input.rpc("getAccountInfo", [mint, { commitment: "confirmed", encoding: "jsonParsed" }]),
      input.rpc("getTokenLargestAccounts", [mint, { commitment: "confirmed" }]),
      input.rpc("getTransaction", [input.acquisition.payload.signature, {
        commitment: "confirmed",
        encoding: "jsonParsed",
        maxSupportedTransactionVersion: 0,
      }]),
      input.rpc("getSignaturesForAddress", [mint, { commitment: "confirmed", limit: 50 }]),
    ]);
    const mintValue = object(mintResponse, "mint response").value;
    if (mintValue === null || mintValue === undefined) throw new Error("mint unavailable");
    const mintAccount = object(mintValue, "mint account");
    payload.tokenProgram = mintAccount.owner === splToken
      ? "spl-token"
      : mintAccount.owner === token2022
        ? "token-2022"
        : "unknown";
    const parsed = object(object(mintAccount.data, "mint data").parsed, "parsed mint");
    if (parsed.type !== "mint") throw new Error("account is not a mint");
    const info = object(parsed.info, "mint info");
    payload.supplyAtoms = integer(info.supply, "mint supply").toString();
    payload.decimals = integer(info.decimals, "mint decimals").toString();
    payload.mintAuthorityDisabled = info.mintAuthority === null;
    payload.freezeAuthorityDisabled = info.freezeAuthority === null;
    const extensions = extensionState(info.extensions);
    payload.tokenExtensions = extensions.names;
    if (payload.tokenProgram === "unknown") rejectReason = "UNKNOWN_TOKEN_PROGRAM";
    if (!payload.mintAuthorityDisabled) rejectReason ||= "MINT_AUTHORITY_ENABLED";
    if (!payload.freezeAuthorityDisabled) rejectReason ||= "FREEZE_AUTHORITY_ENABLED";
    for (const name of extensions.names) {
      rejectReason ||= dangerousExtensions.get(name) ?? (!knownExtensions.has(name)
        ? "TOKEN2022_UNKNOWN_EXTENSION"
        : "");
    }
    let epoch = 0n;
    if (extensions.values.has("transferFeeConfig")) {
      epoch = integer(object(await input.rpc("getEpochInfo", [{ commitment: "confirmed" }]), "epoch info").epoch, "epoch");
    }
    const fee = activeTransferFee(extensions.values.get("transferFeeConfig"), epoch);
    payload.transferFeeBps = fee.bps.toString();
    payload.transferFeeMaximumAtoms = fee.maximum.toString();

    const transaction = object(transactionResponse, "acquisition transaction");
    const message = object(object(transaction.transaction, "acquisition transaction body").message, "acquisition message");
    payload.creator = accountKeys(message.accountKeys)[0] ?? "";

    const holderRows = array(object(holdersResponse, "largest accounts response").value, "largest accounts").slice(0, 10);
    const addresses = holderRows.map((raw) => text(object(raw, "largest account").address, "holder address"));
    const accountsResponse = addresses.length === 0
      ? { value: [] }
      : object(await input.rpc("getMultipleAccounts", [addresses, { commitment: "confirmed", encoding: "jsonParsed" }]), "holder accounts response");
    const accounts = array(accountsResponse.value, "holder accounts");
    let concentration = 0n;
    let creatorInventory = 0n;
    let clusterInventory = 0n;
    const cohort = new Set(input.cohortWallets);
    const screenedAddresses = new Set([
      mint,
      payload.creator,
      input.acquisition.payload.wallet,
      ...input.acquisition.payload.routePrograms,
    ]);
    for (const [index, raw] of holderRows.entries()) {
      const amount = integer(object(raw, "largest account").amount, "holder amount");
      const account = object(accounts[index], "holder account");
      const holderInfo = object(object(object(account.data, "holder data").parsed, "parsed holder").info, "holder info");
      const owner = text(holderInfo.owner, "holder owner");
      screenedAddresses.add(owner);
      if (!input.acquisition.payload.routePrograms.includes(owner) && owner !== "11111111111111111111111111111111") {
        concentration += amount;
      }
      if (owner === payload.creator) creatorInventory += amount;
      if (cohort.has(owner)) clusterInventory += amount;
    }
    const supply = BigInt(payload.supplyAtoms);
    payload.topTenHolderConcentrationBps = (supply === 0n ? 10_000n : concentration * 10_000n / supply).toString();
    payload.creatorInventoryAtoms = creatorInventory.toString();
    payload.clusterInventoryAtoms = clusterInventory.toString();
    payload.sanctionsHit = [...screenedAddresses, ...input.cohortWallets]
      .some((address) => input.sanctionedAddresses.has(address));

    // A candidate already rejected on token control cannot become eligible,
    // and its reject reason is the whole evidence. Skip the mint history scan
    // and the quote ladder — the majority of launches end here. An open
    // position is the exception: its exit still needs a live quote.
    const holding = input.paperPositionAtoms !== undefined && input.paperPositionAtoms > 0n;
    if (rejectReason && !holding) {
      payload.rejectReason = rejectReason;
      return event(input.acquisition, input.observedAtMs, input.sessionId, payload);
    }

    const history = array(historyResponse, "mint history");
    const historySlots = history.map((raw) => integer(object(raw, "mint signature").slot, "mint history slot"));
    const oldestSlot = historySlots.reduce((oldest, slot) => slot < oldest ? slot : oldest, BigInt(input.acquisition.sourceSlot));
    payload.marketAgeSlots = (BigInt(input.acquisition.sourceSlot) - oldestSlot).toString();

    const observedAtMs = input.observedAtMs;
    const confirmedAtMs = BigInt(input.acquisition.payload.confirmedAtMs);
    const windows = [60_000n, 300_000n, 3_600_000n].map((): FlowWindow => ({
      buyers: new Set(),
      boughtAtoms: 0n,
      soldAtoms: 0n,
    }));
    const ignoredBuyers = new Set([
      ...input.cohortWallets,
      ...input.acquisition.payload.routePrograms,
      payload.creator,
    ]);
    let oldestHistoryMs = observedAtMs;
    const earlyBuyers = new Map<string, { firstSeenMs: bigint; boughtAtoms: bigint }>();
    const scanned = history
      .map((raw) => object(raw, "mint signature"))
      .filter((row) => {
        if (row.blockTime === null || row.blockTime === undefined) return false;
        const blockTimeMs = integer(row.blockTime, "mint signature blockTime") * 1000n;
        return blockTimeMs >= confirmedAtMs && blockTimeMs <= observedAtMs;
      });
    const flowTransactions = await fetchFlowTransactions(
      scanned
        .map((row) => text(row.signature, "mint signature signature"))
        .filter((signature) => signature !== input.acquisition.payload.signature),
      input.rpc,
      input.batchRpc,
    );
    for (const row of scanned) {
      const blockTimeMs = integer(row.blockTime, "mint signature blockTime") * 1000n;
      if (blockTimeMs < oldestHistoryMs) oldestHistoryMs = blockTimeMs;
      const signature = text(row.signature, "mint signature signature");
      const flowTransaction = signature === input.acquisition.payload.signature
        ? transactionResponse
        : flowTransactions.get(signature);
      if (flowTransaction === null || flowTransaction === undefined) continue;
      for (const [owner, delta] of tokenOwnerDeltas(flowTransaction, mint)) {
        if (owner === payload.creator && delta < 0n) payload.creatorSold = true;
        if (cohort.has(owner) && delta < 0n) payload.clusterSold = true;
        if (ignoredBuyers.has(owner) || delta === 0n) continue;
        if (delta > 0n) {
          const seen = earlyBuyers.get(owner);
          earlyBuyers.set(owner, {
            firstSeenMs: seen === undefined || blockTimeMs < seen.firstSeenMs
              ? blockTimeMs
              : seen.firstSeenMs,
            boughtAtoms: (seen?.boughtAtoms ?? 0n) + delta,
          });
        }
        for (const [index, duration] of [60_000n, 300_000n, 3_600_000n].entries()) {
          if (observedAtMs - blockTimeMs > duration) continue;
          const window = windows[index]!;
          if (delta > 0n) {
            window.buyers.add(owner);
            window.boughtAtoms += delta;
          } else {
            window.soldAtoms -= delta;
          }
        }
      }
    }
    payload.flowCoverageComplete = history.length < 50 || oldestHistoryMs <= observedAtMs - 3_600_000n;
    payload.flowBuyers = [...earlyBuyers.entries()]
      .sort(([ownerA, a], [ownerB, b]) =>
        a.firstSeenMs === b.firstSeenMs
          ? ownerA < ownerB ? -1 : 1
          : a.firstSeenMs < b.firstSeenMs ? -1 : 1)
      .slice(0, 20)
      .map(([owner, seen]) => ({
        owner,
        firstSeenMs: seen.firstSeenMs.toString(),
        boughtAtoms: seen.boughtAtoms.toString(),
      }));

    let buy: JupiterQuoteResult;
    let sell: JupiterQuoteResult;
    let depthBuy: JupiterQuoteResult;
    let depthSell: JupiterQuoteResult;
    let positionSell: JupiterQuoteResult | undefined;
    // The full-position exit quote runs first and independently of the probe
    // quotes: when a route degrades, the broker still needs executable exit
    // evidence for the open position rather than a defaulted zero.
    if (input.paperPositionAtoms !== undefined && input.paperPositionAtoms > 0n) {
      payload.paperPositionAtoms = input.paperPositionAtoms.toString();
      const positionFee = transferFee(input.paperPositionAtoms, fee.bps, fee.maximum);
      payload.positionTransferFeeAtoms = positionFee.toString();
      const sellablePosition = input.paperPositionAtoms - positionFee;
      payload.positionSellInputAtoms = sellablePosition > 0n ? sellablePosition.toString() : "0";
      if (sellablePosition > 0n) {
        try {
          positionSell = await input.quote(mint, usdc, sellablePosition);
          payload.positionSellOutputUsdMicros = positionSell.outAmount.toString();
          payload.positionSellImpactBps = String(positionSell.priceImpactBps);
        } catch {
          // A missing full-position exit is durable evidence for the paper broker.
        }
      }
    }
    try {
      // Entry and depth are independent ladders; only the sell inside each one
      // depends on its own buy, so the two chains run side by side.
      const [entryLadder, depthLadder] = await Promise.all([
        (async () => {
          const entryBuy = await input.quote(usdc, mint, buyUsdMicros);
          const buyFee = transferFee(entryBuy.outAmount, fee.bps, fee.maximum);
          const sellable = entryBuy.outAmount - buyFee;
          if (sellable <= 0n) throw new Error("transfer fee consumes the paper fill");
          return {
            entryBuy,
            buyFee,
            sellable,
            entrySell: await input.quote(mint, usdc, sellable),
          };
        })(),
        (async () => {
          const probeBuy = await input.quote(usdc, mint, depthUsdMicros);
          const probeFee = transferFee(probeBuy.outAmount, fee.bps, fee.maximum);
          return {
            probeBuy,
            probeSell: await input.quote(mint, usdc, probeBuy.outAmount - probeFee),
          };
        })(),
      ]);
      buy = entryLadder.entryBuy;
      sell = entryLadder.entrySell;
      depthBuy = depthLadder.probeBuy;
      depthSell = depthLadder.probeSell;
      payload.transferFeeBuyAtoms = entryLadder.buyFee.toString();
      payload.transferFeeSellAtoms =
        transferFee(entryLadder.sellable, fee.bps, fee.maximum).toString();
    } catch {
      payload.rejectReason = "REJECT_NO_ROUND_TRIP";
      if (positionSell) {
        payload.quoteContextSlot = positionSell.contextSlot.toString();
        payload.routeLabels = [...new Set(positionSell.routeLabels)];
        payload.migrationStatus = migrationFrom(payload.routeLabels);
      }
      return event(input.acquisition, input.observedAtMs, input.sessionId, payload);
    }
    payload.buyOutputAtoms = buy.outAmount.toString();
    payload.sellOutputUsdMicros = sell.outAmount.toString();
    payload.entryPriceImpactBps = String(buy.priceImpactBps);
    payload.roundTripLossBps = (sell.outAmount >= buyUsdMicros
      ? 0n
      : (buyUsdMicros - sell.outAmount) * 10_000n / buyUsdMicros).toString();
    payload.exitDepthImpactBps = String(depthSell.priceImpactBps);
    payload.exitDepthUsdMicros = depthSell.priceImpactBps <= 1000
      ? depthUsdMicros.toString()
      : "0";
    payload.quoteContextSlot = [
      buy.contextSlot,
      sell.contextSlot,
      depthBuy.contextSlot,
      depthSell.contextSlot,
      ...(positionSell ? [positionSell.contextSlot] : []),
    ]
      .reduce((lowest, slot) => slot < lowest ? slot : lowest)
      .toString();
    payload.routeLabels = [...new Set([
      ...buy.routeLabels,
      ...sell.routeLabels,
      ...(positionSell?.routeLabels ?? []),
    ])];
    // Route labels are evidence, not a gate. The aggregator adds and retires
    // venues continuously, so an allowlist rejects working liquidity as soon
    // as it goes stale — it refused Deriverse, HumidiFi, Riptide and SolFi V2
    // on the first live cohort. Nor would it protect execution: the executor
    // re-quotes at fill time and may route elsewhere entirely. What the venue
    // has to prove is proven directly above, by quotes that are executable in
    // both directions at position size, and bounded at fill by max slippage.
    payload.migrationStatus = migrationFrom(payload.routeLabels);
    payload.marketCapUsdMicros = buy.outAmount === 0n
      ? "0"
      : (supply * buyUsdMicros / buy.outAmount).toString();
    const [oneMinute, fiveMinutes, oneHour] = windows as [FlowWindow, FlowWindow, FlowWindow];
    payload.unlinkedBuyerCount = String(fiveMinutes.buyers.size);
    payload.unlinkedBuyerCount1m = String(oneMinute.buyers.size);
    payload.unlinkedBuyerCount5m = String(fiveMinutes.buyers.size);
    payload.unlinkedBuyerCount1h = String(oneHour.buyers.size);
    payload.netQuoteInflowUsdMicros1m = usdMicros(
      oneMinute.boughtAtoms > oneMinute.soldAtoms ? oneMinute.boughtAtoms - oneMinute.soldAtoms : 0n,
      buyUsdMicros,
      buy.outAmount,
    );
    payload.netQuoteInflowUsdMicros = usdMicros(
      fiveMinutes.boughtAtoms > fiveMinutes.soldAtoms ? fiveMinutes.boughtAtoms - fiveMinutes.soldAtoms : 0n,
      buyUsdMicros,
      buy.outAmount,
    );
    payload.netQuoteInflowUsdMicros1h = usdMicros(
      oneHour.boughtAtoms > oneHour.soldAtoms ? oneHour.boughtAtoms - oneHour.soldAtoms : 0n,
      buyUsdMicros,
      buy.outAmount,
    );
    payload.volumeUsdMicros1m = usdMicros(oneMinute.boughtAtoms + oneMinute.soldAtoms, buyUsdMicros, buy.outAmount);
    payload.volumeUsdMicros5m = usdMicros(fiveMinutes.boughtAtoms + fiveMinutes.soldAtoms, buyUsdMicros, buy.outAmount);
    payload.volumeUsdMicros1h = usdMicros(oneHour.boughtAtoms + oneHour.soldAtoms, buyUsdMicros, buy.outAmount);
    if (payload.sanctionsHit) rejectReason ||= "SANCTIONS_HIT";
    payload.rejectReason = rejectReason;
    payload.snapshotStatus = rejectReason ? "rejected" : "complete";
    return event(input.acquisition, input.observedAtMs, input.sessionId, payload);
  } catch {
    return event(input.acquisition, input.observedAtMs, input.sessionId, payload);
  }
}
