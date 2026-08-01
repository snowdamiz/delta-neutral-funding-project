import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  base58Encode,
  executeLiveIntent,
  loadLiveSigner,
  signTransaction,
  type LiveDeps,
  type LiveIntent,
  type LiveSigner,
} from "./solana-live-executor.js";

function temporarySigner(): { signer: LiveSigner; publicKeyRaw: Buffer } {
  const pair = generateKeyPairSync("ed25519");
  const seed = pair.privateKey.export({ format: "der", type: "pkcs8" }).subarray(16);
  const publicKeyRaw = pair.publicKey.export({ format: "der", type: "spki" }).subarray(12);
  const path = join(mkdtempSync(join(tmpdir(), "live-signer-")), "id.json");
  writeFileSync(path, JSON.stringify([...seed, ...publicKeyRaw]));
  return { signer: loadLiveSigner(path), publicKeyRaw: Buffer.from(publicKeyRaw) };
}

function legacyTransaction(feePayer: Buffer): string {
  const message = Buffer.concat([
    Buffer.from([1, 0, 1]),
    Buffer.from([2]),
    feePayer,
    Buffer.alloc(32, 7),
    Buffer.alloc(32, 9),
    Buffer.from([0]),
  ]);
  return Buffer.concat([Buffer.from([1]), Buffer.alloc(64), message]).toString("base64");
}

test("base58 encodes the system program id", () => {
  assert.equal(base58Encode(Buffer.alloc(32)), "1".repeat(32));
});

test("signs a single-signer transaction for its own fee payer only", () => {
  const { signer, publicKeyRaw } = temporarySigner();
  const signed = Buffer.from(signTransaction(legacyTransaction(publicKeyRaw), signer), "base64");
  const message = signed.subarray(65);
  const signature = signed.subarray(1, 65);
  const { publicKey } = generateKeyPairSync("ed25519");
  void publicKey;
  assert.equal(verify(
    null,
    message,
    { key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), publicKeyRaw]), format: "der", type: "spki" },
    signature,
  ), true);
  assert.throws(
    () => signTransaction(legacyTransaction(Buffer.alloc(32, 3)), signer),
    /fee payer is not the executor key/,
  );
});

function entryIntent(overrides: Partial<LiveIntent> = {}): LiveIntent {
  return {
    intentId: "live:snap-1b",
    kind: "ENTRY",
    mint: "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
    inputUsdMicros: 100_000_000n,
    fractionBps: 0,
    maxSlippageBps: 300,
    liveRemainingAtoms: 0n,
    expiresAtMs: 10_000n,
    ...overrides,
  };
}

function mockDeps(input: {
  signer: LiveSigner;
  publicKeyRaw: Buffer;
  quoteAmounts?: bigint[];
  outputAmount?: string;
  failQuote?: boolean;
}): LiveDeps & { rpcCalls: string[] } {
  const rpcCalls: string[] = [];
  const usdc = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
  return {
    rpcCalls,
    quote: async (_inputMint, outputMint, amount, slippageBps) => {
      if (input.failQuote) throw new Error("Jupiter quote returned 429");
      assert.equal(slippageBps, 300);
      input.quoteAmounts?.push(amount);
      void outputMint;
      return { body: { quoted: amount.toString() }, inAmount: amount, outAmount: 1n };
    },
    swap: async (quoteBody, userPublicKey) => {
      assert.equal(userPublicKey, input.signer.publicKeyBase58);
      assert.equal(typeof quoteBody.quoted, "string");
      return {
        swapTransaction: legacyTransaction(input.publicKeyRaw),
        lastValidBlockHeight: 1_000n,
      };
    },
    rpc: async (method) => {
      rpcCalls.push(method);
      if (method === "sendTransaction") return "5".repeat(64);
      if (method === "getSignatureStatuses") {
        return { value: [{ err: null, confirmationStatus: "confirmed" }] };
      }
      if (method === "getTransaction") {
        return {
          meta: {
            fee: 5000,
            slot: 14,
            preTokenBalances: [],
            postTokenBalances: [{
              mint: entryIntent().mint,
              owner: input.signer.publicKeyBase58,
              uiTokenAmount: { amount: input.outputAmount ?? "2400000" },
            }, {
              mint: usdc,
              owner: input.signer.publicKeyBase58,
              uiTokenAmount: { amount: "97000000" },
            }],
          },
        };
      }
      throw new Error(`unexpected RPC ${method}`);
    },
    signer: input.signer,
    nowMs: () => 1_000n,
    sleepMs: async () => {},
    confirmTimeoutMs: 5_000,
  };
}

test("executes an entry intent and reports the authoritative fill", async () => {
  const { signer, publicKeyRaw } = temporarySigner();
  const deps = mockDeps({ signer, publicKeyRaw });
  const report = await executeLiveIntent(entryIntent(), deps);
  assert.equal(report.status, "filled");
  assert.equal(report.inputAmount, "100000000");
  assert.equal(report.outputAmount, "2400000");
  assert.equal(report.feeLamports, "5000");
  assert.equal(report.slot, "14");
  assert.deepEqual(deps.rpcCalls, ["sendTransaction", "getSignatureStatuses", "getTransaction"]);
});

test("sizes a partial exit from the live remainder and fraction", async () => {
  const { signer, publicKeyRaw } = temporarySigner();
  const quoteAmounts: bigint[] = [];
  const deps = mockDeps({ signer, publicKeyRaw, quoteAmounts });
  const report = await executeLiveIntent(entryIntent({
    kind: "EXIT",
    inputUsdMicros: 0n,
    fractionBps: 4062,
    liveRemainingAtoms: 2_400_000n,
  }), deps);
  assert.equal(report.status, "filled");
  assert.deepEqual(quoteAmounts, [974_880n]);
});

test("reports failures without submitting", async () => {
  const { signer, publicKeyRaw } = temporarySigner();
  const failing = mockDeps({ signer, publicKeyRaw, failQuote: true });
  const report = await executeLiveIntent(entryIntent(), failing);
  assert.equal(report.status, "failed");
  assert.match(report.failureReason ?? "", /Jupiter quote returned 429/);
  assert.deepEqual(failing.rpcCalls, []);

  const expired = mockDeps({ signer, publicKeyRaw });
  const expiredReport = await executeLiveIntent(
    entryIntent({ expiresAtMs: 500n }),
    expired,
  );
  assert.equal(expiredReport.status, "failed");
  assert.equal(expiredReport.failureReason, "INTENT_EXPIRED");
  assert.deepEqual(expired.rpcCalls, []);
});
