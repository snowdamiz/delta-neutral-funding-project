import assert from "node:assert/strict";
import { test } from "node:test";
import {
  captureSolanaWalletFlow,
  type SolanaRpc,
} from "./solana-wallet-flow.js";

const wallet = "11111111111111111111111111111111";
const inputMint = "So11111111111111111111111111111111111111112";
const outputMintA = "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";
const outputMintB = "5Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";

function token(accountIndex: number, mint: string, amount: string) {
  return { accountIndex, mint, owner: wallet, uiTokenAmount: { amount, decimals: 6 } };
}

test("backfills confirmed swaps and emits every acquired mint", async () => {
  const calls: { method: string; params: unknown[] }[] = [];
  const rpc: SolanaRpc = async (method, params) => {
    calls.push({ method, params });
    if (method === "getSignaturesForAddress") {
      const options = params[1] as { before?: string };
      if (!options.before) {
        return [
          { signature: "swap-2", slot: 12, err: null, confirmationStatus: "finalized", blockTime: 102 },
          { signature: "transfer", slot: 11, err: null, confirmationStatus: "confirmed", blockTime: 101 },
        ];
      }
      return [
        { signature: "swap-1", slot: 10, err: null, confirmationStatus: "confirmed", blockTime: 100 },
      ];
    }
    if (method === "getSignatureStatuses") {
      return { value: [{ confirmationStatus: "finalized", err: null }] };
    }
    if (method !== "getTransaction") throw new Error(`unexpected ${method}`);
    const signature = params[0];
    if (signature === "transfer") {
      return {
        slot: 11,
        blockTime: 101,
        transaction: {
          signatures: [signature],
          message: { accountKeys: [wallet], instructions: [{ programId: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA" }] },
        },
        meta: {
          err: null,
          preBalances: [1_000_000],
          postBalances: [995_000],
          preTokenBalances: [token(1, outputMintA, "0")],
          postTokenBalances: [token(1, outputMintA, "5")],
          logMessages: ["Program log: Transfer"],
        },
      };
    }
    return {
      slot: signature === "swap-2" ? 12 : 10,
      blockTime: signature === "swap-2" ? 102 : 100,
      transaction: {
        signatures: [signature],
        message: {
          accountKeys: [wallet],
          instructions: [{ programId: "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4" }],
        },
      },
      meta: {
        err: null,
        preBalances: [2_000_000],
        postBalances: [1_990_000],
        preTokenBalances: [
          token(1, inputMint, "1000000"),
          token(2, outputMintA, "0"),
          token(3, outputMintB, "0"),
        ],
        postTokenBalances: [
          token(1, inputMint, "900000"),
          token(2, outputMintA, "250000"),
          token(3, outputMintB, signature === "swap-2" ? "500000" : "0"),
        ],
        logMessages: ["Program log: Instruction: Route"],
      },
    };
  };

  const capture = await captureSolanaWalletFlow({
    wallet,
    cursor: { signature: "cursor", slot: 9 },
    observedAtMs: 200_000n,
    sessionId: "test",
    rpc,
    pageSize: 2,
    maxPages: 3,
  });

  assert.equal(capture.checkpoint.payload.status, "complete");
  assert.equal(capture.checkpoint.payload.previousSignature, "cursor");
  assert.equal(capture.checkpoint.payload.latestSignature, "swap-2");
  assert.deepEqual(
    capture.acquisitions.map((event) => [
      event.payload.signature,
      event.payload.outputMint,
      event.payload.outputAmountAtoms,
    ]),
    [
      ["swap-1", outputMintA, "250000"],
      ["swap-2", outputMintA, "250000"],
      ["swap-2", outputMintB, "500000"],
    ],
  );
  assert.equal(capture.acquisitions[0]?.payload.inputMint, inputMint);
  assert.equal(capture.acquisitions[0]?.payload.inputAmountAtoms, "100000");
  assert.deepEqual(capture.acquisitions[0]?.payload.routePrograms, [
    "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4",
  ]);
  assert.equal(capture.acquisitions[0]?.payload.confirmedAtMs, "100000");
  assert.equal(
    calls.filter(({ method }) => method === "getTransaction").length,
    3,
  );
});

test("marks a reconnect gap and emits no acquisitions past the cursor slot", async () => {
  const rpc: SolanaRpc = async (method) => {
    if (method === "getSignaturesForAddress") {
      return [{ signature: "too-old", slot: 8, err: null, confirmationStatus: "finalized", blockTime: 99 }];
    }
    if (method === "getSignatureStatuses") {
      return { value: [null] };
    }
    throw new Error(`unexpected ${method}`);
  };

  const capture = await captureSolanaWalletFlow({
    wallet,
    cursor: { signature: "missing", slot: 9 },
    observedAtMs: 200_000n,
    sessionId: "test",
    rpc,
    pageSize: 2,
    maxPages: 2,
  });

  assert.equal(capture.checkpoint.payload.status, "gap");
  assert.equal(capture.checkpoint.payload.reason, "cursor_not_recovered");
  assert.equal(capture.acquisitions.length, 0);
});

test("baselines a newly followed wallet instead of paging its history", async () => {
  const calls: { method: string; params: unknown[] }[] = [];
  const rpc: SolanaRpc = async (method, params) => {
    calls.push({ method, params });
    if (method === "getSignaturesForAddress") {
      return [{ signature: "newest", slot: 900, err: null, confirmationStatus: "confirmed", blockTime: 500 }];
    }
    throw new Error(`a baseline must not call ${method}`);
  };

  const capture = await captureSolanaWalletFlow({
    wallet: "11111111111111111111111111111111",
    observedAtMs: 200_000n,
    sessionId: "baseline",
    rpc,
  });

  // A wallet deeper than the page budget would otherwise latch gapped, and
  // its historical swaps are not tradeable.
  assert.equal(capture.checkpoint.payload.status, "complete");
  assert.equal(capture.checkpoint.payload.previousSignature, "");
  assert.equal(capture.checkpoint.payload.latestSignature, "newest");
  assert.deepEqual(capture.acquisitions, []);
  assert.deepEqual(calls.map((call) => call.method), ["getSignaturesForAddress"]);
  assert.equal((calls[0]?.params[1] as { limit: number }).limit, 1);
});
