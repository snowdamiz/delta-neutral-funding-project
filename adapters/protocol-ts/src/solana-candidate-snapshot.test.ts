import assert from "node:assert/strict";
import { test } from "node:test";
import {
  snapshotSolanaCandidate,
  type JupiterQuote,
} from "./solana-candidate-snapshot.js";
import type { SolanaRpc, SolanaWalletAcquisitionEvent } from "./solana-wallet-flow.js";

const wallet = "11111111111111111111111111111111";
const creator = "2Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";
const clusterWallet = "3Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";
const mint = "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";
const jupiter = "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4";
const tokenProgram = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";

const acquisition: SolanaWalletAcquisitionEvent = {
  schemaVersion: 1,
  eventId: "acquisition-1",
  eventType: "SolanaWalletAcquisition",
  source: `solana-wallet:${wallet}:${mint}`,
  observedAtMs: "200000",
  sourceSlot: "12",
  sourceSequence: "swap-1",
  idempotencyKey: "acquisition-1",
  rawPayloadHash: "a".repeat(64),
  payload: {
    wallet,
    signature: "swap-1",
    confirmedAtMs: "100000",
    inputMint: "So11111111111111111111111111111111111111112",
    inputAmountAtoms: "100000",
    outputMint: mint,
    outputAmountAtoms: "250000",
    outputDecimals: "6",
    routePrograms: [jupiter],
  },
};

function account(owner: string, amount: string) {
  return {
    data: { parsed: { info: { owner, tokenAmount: { amount } }, type: "account" } },
    owner: tokenProgram,
  };
}

function rpc(): SolanaRpc {
  return async (method, params) => {
    if (method === "getAccountInfo") {
      assert.equal(params[0], mint);
      return { value: {
        owner: tokenProgram,
        data: { parsed: { type: "mint", info: {
          decimals: 6,
          supply: "1000000",
          mintAuthority: null,
          freezeAuthority: null,
          extensions: [],
        } } },
      } };
    }
    if (method === "getTokenLargestAccounts") {
      return { value: [
        { address: "holder-a", amount: "300000" },
        { address: "holder-b", amount: "100000" },
        { address: "holder-c", amount: "50000" },
      ] };
    }
    if (method === "getMultipleAccounts") {
      return { value: [
        account(creator, "300000"),
        account(clusterWallet, "100000"),
        account(jupiter, "50000"),
      ] };
    }
    if (method === "getTransaction") {
      return { transaction: { message: { accountKeys: [creator, wallet] } } };
    }
    if (method === "getSignaturesForAddress") return [];
    throw new Error(`unexpected ${method}`);
  };
}

test("snapshots token control, concentration, cluster inventory, and round trip", async () => {
  const quote: JupiterQuote = async (inputMint, outputMint, amount) => {
    if (inputMint.endsWith("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v") || inputMint === "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v") {
      return {
        inputMint,
        outputMint,
        inAmount: amount,
        outAmount: amount === 10_000_000n ? 250_000n : 2_000_000n,
        priceImpactBps: amount === 10_000_000n ? 100 : 400,
        contextSlot: 13n,
        routeLabels: ["Pump.fun"],
      };
    }
    return {
      inputMint,
      outputMint,
      inAmount: amount,
      outAmount: amount === 250_000n ? 9_500_000n : amount === 100_000n ? 3_800_000n : 80_000_000n,
      priceImpactBps: amount === 2_000_000n ? 900 : 200,
      contextSlot: 13n,
      routeLabels: ["Pump.fun"],
    };
  };

  const event = await snapshotSolanaCandidate({
    acquisition,
    observedAtMs: 201_000n,
    sessionId: "test",
    rpc: rpc(),
    quote,
    cohortWallets: [wallet, clusterWallet],
    sanctionedAddresses: new Set(),
    positionUsdMicros: 10_000_000n,
    exitDepthMultiple: 10n,
    paperPositionAtoms: 100_000n,
  });

  assert.equal(event.payload.snapshotStatus, "complete");
  assert.equal(event.payload.tokenProgram, "spl-token");
  assert.equal(event.payload.mintAuthorityDisabled, true);
  assert.equal(event.payload.freezeAuthorityDisabled, true);
  assert.equal(event.payload.topTenHolderConcentrationBps, "4000");
  assert.equal(event.payload.creator, creator);
  assert.equal(event.payload.creatorInventoryAtoms, "300000");
  assert.equal(event.payload.clusterInventoryAtoms, "100000");
  assert.equal(event.payload.entryPriceImpactBps, "100");
  assert.equal(event.payload.roundTripLossBps, "500");
  assert.equal(event.payload.exitDepthUsdMicros, "100000000");
  assert.equal(event.payload.exitDepthImpactBps, "900");
  assert.equal(event.payload.positionSellInputAtoms, "100000");
  assert.equal(event.payload.positionSellOutputUsdMicros, "3800000");
  assert.equal(event.payload.positionSellImpactBps, "200");
  assert.deepEqual(event.payload.routeLabels, ["Pump.fun"]);
  assert.equal(event.payload.migrationStatus, "pre_migration");
  assert.equal(event.payload.sanctionsHit, false);
});

test("persists a no-round-trip reject instead of throwing", async () => {
  const event = await snapshotSolanaCandidate({
    acquisition,
    observedAtMs: 201_000n,
    sessionId: "test",
    rpc: rpc(),
    quote: async () => { throw new Error("no route"); },
    cohortWallets: [wallet],
    sanctionedAddresses: new Set(),
  positionUsdMicros: 10_000_000n,
  exitDepthMultiple: 10n,
  });
  assert.equal(event.payload.snapshotStatus, "rejected");
  assert.equal(event.payload.rejectReason, "REJECT_NO_ROUND_TRIP");
  assert.equal(event.payload.buyInputUsdMicros, "10000000");
});

test("applies the active Token-2022 transfer fee in both directions", async () => {
  const baseRpc = rpc();
  const token2022Rpc: SolanaRpc = async (method, params) => {
    if (method === "getAccountInfo") {
      return { value: {
        owner: "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
        data: { parsed: { type: "mint", info: {
          decimals: 6,
          supply: "1000000",
          mintAuthority: null,
          freezeAuthority: null,
          extensions: [{ extension: "transferFeeConfig", state: {
            olderTransferFee: {
              epoch: "0",
              transferFeeBasisPoints: "100",
              maximumFee: "1000",
            },
            newerTransferFee: {
              epoch: "10",
              transferFeeBasisPoints: "200",
              maximumFee: "1000",
            },
          } }],
        } } },
      } };
    }
    if (method === "getEpochInfo") return { epoch: "10" };
    return baseRpc(method, params);
  };
  const sellAmounts: bigint[] = [];
  const quote: JupiterQuote = async (inputMint, outputMint, amount) => {
    const buying = inputMint === "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
    if (!buying) sellAmounts.push(amount);
    return {
      inputMint,
      outputMint,
      inAmount: amount,
      outAmount: buying
        ? amount === 10_000_000n ? 250_000n : 2_000_000n
        : amount === 249_000n ? 9_400_000n : 80_000_000n,
      priceImpactBps: buying ? 100 : 200,
      contextSlot: 13n,
      routeLabels: ["Pump.fun"],
    };
  };

  const event = await snapshotSolanaCandidate({
    acquisition,
    observedAtMs: 201_000n,
    sessionId: "test-token-2022",
    rpc: token2022Rpc,
    quote,
    cohortWallets: [wallet],
    sanctionedAddresses: new Set(),
  positionUsdMicros: 10_000_000n,
  exitDepthMultiple: 10n,
  });

  assert.equal(event.payload.snapshotStatus, "complete");
  assert.equal(event.payload.tokenProgram, "token-2022");
  assert.equal(event.payload.transferFeeBps, "200");
  assert.equal(event.payload.transferFeeBuyAtoms, "1000");
  assert.equal(event.payload.transferFeeSellAtoms, "1000");
  assert.deepEqual(sellAmounts, [249_000n, 1_999_000n]);
});

test("derives confirmed post-trigger organic flow and cluster sells", async () => {
  const buyer = "5Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";
  const baseRpc = rpc();
  const flowRpc: SolanaRpc = async (method, params) => {
    if (method === "getSignaturesForAddress") {
      return [
        { signature: "buyer-1", slot: 14, blockTime: 200 },
        { signature: "cluster-sell", slot: 13, blockTime: 150 },
      ];
    }
    if (method === "getTransaction" && params[0] !== "swap-1") {
      const owner = params[0] === "buyer-1" ? buyer : clusterWallet;
      const before = params[0] === "buyer-1" ? "0" : "20000";
      const after = params[0] === "buyer-1" ? "10000" : "15000";
      return { meta: {
        preTokenBalances: [{ mint, owner, uiTokenAmount: { amount: before } }],
        postTokenBalances: [{ mint, owner, uiTokenAmount: { amount: after } }],
      } };
    }
    return baseRpc(method, params);
  };
  const quote: JupiterQuote = async (inputMint, outputMint, amount) => ({
    inputMint,
    outputMint,
    inAmount: amount,
    outAmount: inputMint === mint ? 9_500_000n : 250_000n,
    priceImpactBps: 100,
    contextSlot: 14n,
    routeLabels: ["Pump.fun"],
  });

  const event = await snapshotSolanaCandidate({
    acquisition,
    observedAtMs: 201_000n,
    sessionId: "test-flow",
    rpc: flowRpc,
    quote,
    cohortWallets: [wallet, clusterWallet],
    sanctionedAddresses: new Set(),
  positionUsdMicros: 10_000_000n,
  exitDepthMultiple: 10n,
  });

  assert.equal(event.payload.flowCoverageComplete, true);
  assert.equal(event.payload.unlinkedBuyerCount, "1");
  assert.equal(event.payload.unlinkedBuyerCount1m, "1");
  assert.equal(event.payload.unlinkedBuyerCount5m, "1");
  assert.equal(event.payload.unlinkedBuyerCount1h, "1");
  assert.equal(event.payload.volumeUsdMicros1m, "400000");
  assert.equal(event.payload.netQuoteInflowUsdMicros, "400000");
  assert.equal(event.payload.clusterSold, true);
  assert.equal(event.payload.creatorSold, false);
});

test("abandons a hard-rejected candidate before the history scan and quotes", async () => {
  const calls: string[] = [];
  const baseRpc = rpc();
  const countingRpc: SolanaRpc = async (method, params) => {
    calls.push(method);
    if (method === "getAccountInfo") {
      const response = await baseRpc(method, params) as {
        value: { data: { parsed: { info: Record<string, unknown> } } };
      };
      // A live mint authority can never become eligible.
      response.value.data.parsed.info.mintAuthority = creator;
      return response;
    }
    return baseRpc(method, params);
  };
  let quoted = 0;
  const quote: JupiterQuote = async () => {
    quoted += 1;
    throw new Error("a rejected candidate must never be quoted");
  };

  const event = await snapshotSolanaCandidate({
    acquisition,
    observedAtMs: 201_000n,
    sessionId: "test-reject",
    rpc: countingRpc,
    quote,
    cohortWallets: [wallet],
    sanctionedAddresses: new Set(),
    positionUsdMicros: 100_000_000n,
    exitDepthMultiple: 10n,
  });

  assert.equal(event.payload.snapshotStatus, "rejected");
  assert.equal(event.payload.rejectReason, "MINT_AUTHORITY_ENABLED");
  assert.equal(quoted, 0, "no quote may be spent on a rejected candidate");
  // Only the opening parallel reads run; the per-signature history scan does not.
  assert.equal(calls.filter((method) => method === "getTransaction").length, 1);
});

test("fetches the history scan in one batch when the provider supports it", async () => {
  const buyer = "5Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";
  const baseRpc = rpc();
  const single: string[] = [];
  const batches: number[] = [];
  const flowTransaction = (owner: string) => ({ meta: {
    preTokenBalances: [{ mint, owner, uiTokenAmount: { amount: "0" } }],
    postTokenBalances: [{ mint, owner, uiTokenAmount: { amount: "10000" } }],
  } });
  const flowRpc: SolanaRpc = async (method, params) => {
    if (method === "getTransaction" && params[0] !== "swap-1") single.push(String(params[0]));
    if (method === "getSignaturesForAddress") {
      return [
        { signature: "buyer-1", slot: 14, blockTime: 200 },
        { signature: "buyer-2", slot: 14, blockTime: 200 },
        { signature: "buyer-3", slot: 14, blockTime: 200 },
      ];
    }
    return baseRpc(method, params);
  };
  const quote: JupiterQuote = async (inputMint, outputMint, amount) => ({
    inputMint,
    outputMint,
    inAmount: amount,
    outAmount: inputMint === mint ? 9_500_000n : 250_000n,
    priceImpactBps: 100,
    contextSlot: 14n,
    routeLabels: ["Pump.fun"],
  });

  const event = await snapshotSolanaCandidate({
    acquisition,
    observedAtMs: 201_000n,
    sessionId: "test-batch",
    rpc: flowRpc,
    quote,
    cohortWallets: [wallet],
    sanctionedAddresses: new Set(),
    positionUsdMicros: 10_000_000n,
    exitDepthMultiple: 10n,
    batchRpc: async (requests) => {
      batches.push(requests.length);
      return requests.map((_, index) => flowTransaction(`${buyer.slice(0, 43)}${index}`));
    },
  });

  assert.deepEqual(batches, [3], "the history scan is one round trip");
  assert.deepEqual(single, [], "no per-signature call survives the batch path");
  assert.equal(event.payload.unlinkedBuyerCount, "3");
});
