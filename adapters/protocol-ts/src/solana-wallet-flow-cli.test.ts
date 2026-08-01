import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { pollSolanaWalletFlow } from "./solana-wallet-flow-cli.js";
import type { JupiterQuote } from "./solana-candidate-snapshot.js";
import { signBody } from "./transport.js";

const wallet = "11111111111111111111111111111111";
const inputMint = "So11111111111111111111111111111111111111112";
const outputMint = "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";

test("delivers read-only acquisitions before the durable checkpoint", async () => {
  const rpcMethods: string[] = [];
  const delivered: { eventType: string; signature: string }[] = [];
  const server = createServer((request, response) => {
    void (async () => {
      if (request.method === "GET") {
        assert.equal(request.url, "/v1/solana-wallet-flow");
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ cursors: [], openMints: [{
          decision: "WATCH",
          snapshotEventId: "snapshot-old",
          snapshotObservedAtMs: "150000",
          positionAtoms: "100000",
          acquisition: {
            schemaVersion: 1,
            eventId: "acquisition-old",
            eventType: "SolanaWalletAcquisition",
            source: `solana-wallet:${wallet}:${outputMint}`,
            observedAtMs: "150000",
            sourceSlot: "9",
            sourceSequence: "swap-old",
            idempotencyKey: "acquisition-old",
            rawPayloadHash: "a".repeat(64),
            payload: {
              wallet,
              signature: "swap-old",
              confirmedAtMs: "100000",
              inputMint,
              inputAmountAtoms: "100000",
              outputMint,
              outputAmountAtoms: "250000",
              outputDecimals: "6",
              routePrograms: ["JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4"],
            },
          },
        }] }));
        return;
      }
      const chunks: Buffer[] = [];
      for await (const chunk of request) chunks.push(Buffer.from(chunk));
      const raw = Buffer.concat(chunks).toString();
      if (request.url === "/rpc") {
        const call = JSON.parse(raw) as { id: number; method: string; params: unknown[] };
        rpcMethods.push(call.method);
        let result: unknown;
        if (call.method === "getSignaturesForAddress") {
          result = call.params[0] === outputMint ? [] : [{
            signature: "swap-1",
            slot: 10,
            err: null,
            confirmationStatus: "confirmed",
            blockTime: 100,
          }];
        } else if (call.method === "getAccountInfo") {
          result = { value: {
            owner: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
            data: { parsed: { type: "mint", info: {
              decimals: 6,
              supply: "1000000",
              mintAuthority: null,
              freezeAuthority: null,
              extensions: [],
            } } },
          } };
        } else if (call.method === "getTokenLargestAccounts") {
          result = { value: [] };
        } else if (call.method === "getMultipleAccounts") {
          result = { value: [] };
        } else if (call.method === "getTransaction") {
          result = {
            slot: 10,
            blockTime: 100,
            transaction: {
              signatures: ["swap-1"],
              message: {
                accountKeys: [wallet],
                instructions: [{ programId: "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4" }],
              },
            },
            meta: {
              err: null,
              preBalances: [2_000_000],
              postBalances: [1_990_000],
              preTokenBalances: [{
                accountIndex: 1,
                mint: inputMint,
                owner: wallet,
                uiTokenAmount: { amount: "1000000", decimals: 6 },
              }, {
                accountIndex: 2,
                mint: outputMint,
                owner: wallet,
                uiTokenAmount: { amount: "0", decimals: 6 },
              }],
              postTokenBalances: [{
                accountIndex: 1,
                mint: inputMint,
                owner: wallet,
                uiTokenAmount: { amount: "900000", decimals: 6 },
              }, {
                accountIndex: 2,
                mint: outputMint,
                owner: wallet,
                uiTokenAmount: { amount: "250000", decimals: 6 },
              }],
              logMessages: ["Program log: Instruction: Route"],
            },
          };
        } else {
          throw new Error(`unexpected RPC ${call.method}`);
        }
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ jsonrpc: "2.0", id: call.id, result }));
        return;
      }
      assert.equal(request.url, "/v1/events");
      assert.equal(request.headers["x-adapter-signature"], signBody("secret", raw));
      const event = JSON.parse(raw) as {
        eventType: string;
        payload: { signature?: string; latestSignature?: string };
      };
      delivered.push({
        eventType: event.eventType,
        signature: event.payload.signature ?? event.payload.latestSignature ?? "",
      });
      response.writeHead(202, { "content-type": "application/json" });
      response.end('{"inserted":true}');
    })().catch((error: unknown) => {
      response.writeHead(500).end(String(error));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert(address && typeof address !== "string");
  const base = `http://127.0.0.1:${address.port}`;

  try {
    const quote: JupiterQuote = async (inputMint, outputMint, amount) => ({
      inputMint,
      outputMint,
      inAmount: amount,
      outAmount: inputMint === outputMint
        ? amount === 250_000n ? 9_500_000n : 80_000_000n
        : amount === 10_000_000n ? 250_000n : 2_000_000n,
      priceImpactBps: 100,
      contextSlot: 10n,
      routeLabels: ["Pump.fun"],
    });
    const result = await pollSolanaWalletFlow({
      wallets: [wallet],
      collectorUrl: `${base}/v1/events`,
      rpcUrl: `${base}/rpc`,
      hmacSecret: "secret",
      sessionId: "test",
      timeoutMs: 1000,
      observedAtMs: 200_000n,
      quote,
      sanctionedAddresses: new Set(),
    });
    assert.deepEqual(result, { acquisitions: 1, snapshots: 2, checkpoints: 1, gaps: 0 });
    assert(rpcMethods.every((method) => method !== "sendTransaction"));
    assert.deepEqual(delivered, [
      { eventType: "SolanaWalletAcquisition", signature: "swap-1" },
      { eventType: "SolanaCandidateSnapshot", signature: "swap-1" },
      { eventType: "SolanaWalletCheckpoint", signature: "swap-1" },
      { eventType: "SolanaCandidateSnapshot", signature: "swap-old" },
    ]);
  } finally {
    server.close();
  }
});
