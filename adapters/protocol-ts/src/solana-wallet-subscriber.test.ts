import assert from "node:assert/strict";
import test from "node:test";
import { createWalletSubscriber, websocketUrlFrom } from "./solana-wallet-subscriber.js";

const WALLET_A = "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";
const WALLET_B = "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiK";

type Sent = { id?: number; method: string; params: unknown[] };

class FakeSocket {
  static last: FakeSocket | undefined;
  static opened = 0;
  readyState = 1;
  sent: Sent[] = [];
  acked = new Set<number>();
  closed = false;
  onopen: (() => void) | undefined;
  onmessage: ((event: MessageEvent) => void) | undefined;
  onerror: (() => void) | undefined;
  onclose: (() => void) | undefined;

  constructor() {
    FakeSocket.last = this;
    FakeSocket.opened += 1;
  }

  send(raw: string): void {
    this.sent.push(JSON.parse(raw) as Sent);
  }

  close(): void {
    this.closed = true;
    this.readyState = 3;
  }

  deliver(message: unknown): void {
    this.onmessage?.({ data: JSON.stringify(message) } as MessageEvent);
  }

  /** Answer the oldest unanswered subscribe request, as a server would. */
  ack(subscriptionId: number, method = "logsSubscribe"): void {
    const request = this.sent.find(
      (entry) => entry.method === method && !this.acked.has(entry.id!),
    );
    assert(request?.id !== undefined, `no ${method} request to acknowledge`);
    this.acked.add(request.id);
    this.deliver({ jsonrpc: "2.0", id: request.id, result: subscriptionId });
  }

  subscribedMentions(): string[] {
    return this.sent
      .filter((entry) => entry.method === "logsSubscribe")
      .map((entry) => (entry.params[0] as { mentions: string[] }).mentions[0]!);
  }
}

function subscriber(overrides: Partial<Parameters<typeof createWalletSubscriber>[0]> = {}) {
  const wallets: string[] = [];
  let resubscribes = 0;
  const handle = createWalletSubscriber({
    wsUrl: "wss://example.invalid/v2/key",
    connect: () => new FakeSocket() as unknown as WebSocket,
    onWallet: (wallet) => wallets.push(wallet),
    onResubscribed: () => { resubscribes += 1; },
    ...overrides,
  });
  return { handle, wallets, resubscribes: () => resubscribes };
}

test("derives the socket URL from the RPC endpoint", () => {
  assert.equal(
    websocketUrlFrom("https://solana-mainnet.g.alchemy.com/v2/key"),
    "wss://solana-mainnet.g.alchemy.com/v2/key",
  );
  assert.equal(websocketUrlFrom("http://127.0.0.1:8899"), "ws://127.0.0.1:8899");
});

test("subscribes per wallet with a single-address mentions filter", () => {
  const { handle } = subscriber();
  const socket = FakeSocket.last!;
  socket.onopen!();
  handle.reconcile([WALLET_A, WALLET_B]);

  assert.deepEqual(socket.subscribedMentions(), [WALLET_A, WALLET_B]);
  for (const entry of socket.sent.filter((s) => s.method === "logsSubscribe")) {
    // More than one address per filter is an Invalid params error upstream.
    assert.equal((entry.params[0] as { mentions: string[] }).mentions.length, 1);
    assert.deepEqual(entry.params[1], { commitment: "confirmed" });
  }
  // A slot subscription proves the socket is alive while wallets are quiet.
  assert(socket.sent.some((entry) => entry.method === "slotSubscribe"));
  handle.close();
});

test("adds and drops wallets on a live connection without reconnecting", () => {
  const { handle } = subscriber();
  const socket = FakeSocket.last!;
  const opened = FakeSocket.opened;
  socket.onopen!();

  handle.reconcile([WALLET_A]);
  socket.ack(11);
  assert.deepEqual(handle.subscribedWallets(), [WALLET_A]);

  handle.reconcile([WALLET_A, WALLET_B]);
  socket.ack(12);
  assert.deepEqual(handle.subscribedWallets().sort(), [WALLET_A, WALLET_B].sort());
  // The established wallet is not re-subscribed.
  assert.equal(socket.subscribedMentions().filter((w) => w === WALLET_A).length, 1);

  handle.reconcile([WALLET_B]);
  assert.deepEqual(handle.subscribedWallets(), [WALLET_B]);
  assert(socket.sent.some((entry) => entry.method === "logsUnsubscribe" && entry.params[0] === 11));
  assert.equal(FakeSocket.opened, opened, "cohort changes must not reconnect");
  handle.close();
});

test("routes a notification to its wallet and ignores failed transactions", () => {
  const { handle, wallets } = subscriber();
  const socket = FakeSocket.last!;
  socket.onopen!();
  handle.reconcile([WALLET_A, WALLET_B]);
  socket.ack(11);
  socket.ack(12);

  socket.deliver({
    jsonrpc: "2.0",
    method: "logsNotification",
    params: { subscription: 12, result: { value: { signature: "sig-1", err: null, logs: [] } } },
  });
  socket.deliver({
    jsonrpc: "2.0",
    method: "logsNotification",
    params: { subscription: 11, result: { value: { signature: "sig-2", err: { InstructionError: [] } } } },
  });
  socket.deliver({
    jsonrpc: "2.0",
    method: "logsNotification",
    params: { subscription: 99, result: { value: { signature: "sig-3", err: null } } },
  });

  assert.deepEqual(wallets, [WALLET_B]);
  handle.close();
});

test("re-subscribes after a drop and asks for a sweep before trusting the stream", async () => {
  const { handle, resubscribes } = subscriber({ maxBackoffMs: 1 });
  const first = FakeSocket.last!;
  first.onopen!();
  handle.reconcile([WALLET_A]);
  first.ack(11);
  assert.equal(resubscribes(), 1);

  first.onclose!();
  await new Promise((resolve) => setTimeout(resolve, 20));
  const second = FakeSocket.last!;
  assert.notEqual(second, first, "a dropped socket must be replaced");
  second.onopen!();

  assert.deepEqual(second.subscribedMentions(), [WALLET_A]);
  assert.equal(resubscribes(), 2, "every reconnect must trigger a backfill sweep");
  handle.close();
});

test("reconnects when the slot heartbeat goes quiet", async () => {
  let clock = 1_000_000;
  const { handle } = subscriber({
    heartbeatTimeoutMs: 3000,
    maxBackoffMs: 1,
    now: () => clock,
  });
  const first = FakeSocket.last!;
  first.onopen!();
  handle.reconcile([WALLET_A]);

  clock += 10_000;
  await new Promise((resolve) => setTimeout(resolve, 1200));
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert(first.closed, "a silent socket must be closed");
  assert.notEqual(FakeSocket.last, first, "a silent socket must be replaced");
  handle.close();
});
