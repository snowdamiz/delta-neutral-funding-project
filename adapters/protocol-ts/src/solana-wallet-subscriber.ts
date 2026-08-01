// Realtime followed-wallet acquisition capture.
//
// One `logsSubscribe` per followed wallet on a single socket: the mentions
// filter accepts exactly one address, and providers cap subscriptions per
// connection far above this strategy's 100-wallet cohort. Subscriptions are
// reconciled against the cohort the collector serves, so adding a wallet in
// the console reaches the socket on the next reconcile with no provider-side
// configuration and no restart — the reason this is a subscription rather
// than a provider webhook.
//
// A log notification carries only the signature, so it is a trigger: the
// caller still loads and decodes the transaction through the durable cursor
// path. That keeps gap detection authoritative — a socket is best-effort
// delivery, and the paper-validation gate requires complete capture.

export type SubscriberLog = {
  info: (event: string, fields: Record<string, unknown>) => void;
};

export type SubscriberOptions = {
  wsUrl: string;
  commitment?: string;
  /** Reconnect ceiling; the first retry is one second. */
  maxBackoffMs?: number;
  /** Force a reconnect when the slot heartbeat goes quiet this long. */
  heartbeatTimeoutMs?: number;
  /** Injected for tests; defaults to the platform WebSocket. */
  connect?: (url: string) => WebSocket;
  now?: () => number;
  log?: SubscriberLog;
  /** A followed wallet transacted. Coalesce and capture through the cursor. */
  onWallet: (wallet: string) => void;
  /** Fired after every (re)connect: sweep before trusting the stream. */
  onResubscribed: () => void;
};

type Pending = { wallet: string | null };

/** Timers here must never hold the process open; the caller's loop owns that. */
function unref(timer: { unref?: () => void }): void {
  timer.unref?.();
}

export type WalletSubscriber = {
  reconcile: (wallets: string[]) => void;
  subscribedWallets: () => string[];
  connected: () => boolean;
  close: () => void;
};

export function createWalletSubscriber(options: SubscriberOptions): WalletSubscriber {
  const commitment = options.commitment ?? "confirmed";
  const maxBackoffMs = options.maxBackoffMs ?? 30_000;
  const heartbeatTimeoutMs = options.heartbeatTimeoutMs ?? 45_000;
  const now = options.now ?? (() => Date.now());
  const open = options.connect ?? ((url: string) => new WebSocket(url));
  const log = options.log ?? { info: () => {} };

  let socket: WebSocket | undefined;
  let closed = false;
  let ready = false;
  let attempt = 0;
  let requestId = 0;
  let lastBeatMs = now();
  let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  let heartbeatTimer: ReturnType<typeof setInterval> | undefined;
  let wanted: string[] = [];
  const pending = new Map<number, Pending>();
  const subscriptionByWallet = new Map<string, number>();
  const walletBySubscription = new Map<number, string>();

  const send = (method: string, params: unknown[], wallet: string | null): void => {
    if (!socket || socket.readyState !== 1) return;
    const id = ++requestId;
    pending.set(id, { wallet });
    socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  };

  const subscribe = (wallet: string): void => {
    if (subscriptionByWallet.has(wallet)) return;
    // Reserve the slot immediately so a reconcile during the round trip does
    // not open a second subscription for the same wallet.
    subscriptionByWallet.set(wallet, 0);
    send("logsSubscribe", [{ mentions: [wallet] }, { commitment }], wallet);
  };

  const unsubscribe = (wallet: string): void => {
    const id = subscriptionByWallet.get(wallet);
    subscriptionByWallet.delete(wallet);
    if (id === undefined || id === 0) return;
    walletBySubscription.delete(id);
    send("logsUnsubscribe", [id], null);
  };

  const applyWanted = (): void => {
    if (!ready) return;
    for (const wallet of wanted) subscribe(wallet);
    for (const wallet of [...subscriptionByWallet.keys()]) {
      if (!wanted.includes(wallet)) unsubscribe(wallet);
    }
  };

  const handle = (raw: string): void => {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      return;
    }
    if (typeof message.id === "number") {
      const request = pending.get(message.id);
      pending.delete(message.id);
      if (!request?.wallet) return;
      if (typeof message.result !== "number") {
        // A rejected subscription must not look established.
        subscriptionByWallet.delete(request.wallet);
        log.info("solana_wallet_subscribe_failed", {
          wallet: request.wallet,
          reason: JSON.stringify(message.error ?? message.result ?? null).slice(0, 200),
        });
        return;
      }
      if (!subscriptionByWallet.has(request.wallet)) {
        // Unsubscribed while the request was in flight.
        send("logsUnsubscribe", [message.result], null);
        return;
      }
      subscriptionByWallet.set(request.wallet, message.result);
      walletBySubscription.set(message.result, request.wallet);
      return;
    }
    if (message.method === "slotNotification") {
      lastBeatMs = now();
      return;
    }
    if (message.method !== "logsNotification") return;
    lastBeatMs = now();
    const params = message.params as { subscription?: number; result?: unknown } | undefined;
    const wallet = params?.subscription === undefined
      ? undefined
      : walletBySubscription.get(params.subscription);
    if (!wallet) return;
    const value = (params?.result as { value?: { signature?: unknown; err?: unknown } } | undefined)?.value;
    if (typeof value?.signature !== "string") return;
    // A failed transaction acquires nothing; the capture path skips it too.
    if (value.err !== null && value.err !== undefined) return;
    options.onWallet(wallet);
  };

  const scheduleReconnect = (reason: string): void => {
    if (closed || reconnectTimer) return;
    ready = false;
    socket = undefined;
    pending.clear();
    subscriptionByWallet.clear();
    walletBySubscription.clear();
    const delay = Math.min(maxBackoffMs, 1000 * 2 ** attempt);
    attempt += 1;
    log.info("solana_wallet_socket_reconnecting", { reason, delayMs: delay });
    reconnectTimer = setTimeout(() => {
      reconnectTimer = undefined;
      connect();
    }, delay);
    unref(reconnectTimer);
  };

  function connect(): void {
    if (closed) return;
    let next: WebSocket;
    try {
      next = open(options.wsUrl);
    } catch (error) {
      scheduleReconnect(error instanceof Error ? error.message : String(error));
      return;
    }
    socket = next;
    next.onopen = () => {
      attempt = 0;
      ready = true;
      lastBeatMs = now();
      // Slot notifications are the liveness signal: a followed wallet can be
      // silent for hours, so quiet logs cannot distinguish a calm cohort from
      // a dead socket.
      send("slotSubscribe", [], null);
      applyWanted();
      log.info("solana_wallet_socket_open", { wallets: wanted.length });
      options.onResubscribed();
    };
    next.onmessage = (event: MessageEvent) => {
      handle(typeof event.data === "string" ? event.data : String(event.data));
    };
    next.onerror = () => scheduleReconnect("socket error");
    next.onclose = () => scheduleReconnect("socket closed");
  }

  heartbeatTimer = setInterval(() => {
    if (closed || !ready) return;
    if (now() - lastBeatMs > heartbeatTimeoutMs) {
      try { socket?.close(); } catch { /* the reconnect path owns recovery */ }
      scheduleReconnect("heartbeat timeout");
    }
  }, Math.max(1000, Math.floor(heartbeatTimeoutMs / 3)));
  unref(heartbeatTimer);

  connect();

  return {
    reconcile: (wallets: string[]) => {
      wanted = [...new Set(wallets)];
      applyWanted();
    },
    subscribedWallets: () => [...subscriptionByWallet.keys()].sort(),
    connected: () => ready,
    close: () => {
      closed = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      if (heartbeatTimer) clearInterval(heartbeatTimer);
      try { socket?.close(); } catch { /* already gone */ }
      socket = undefined;
      ready = false;
    },
  };
}

/** Alchemy and every other provider serve the socket on the RPC path. */
export function websocketUrlFrom(rpcUrl: string): string {
  return rpcUrl.replace(/^http:/, "ws:").replace(/^https:/, "wss:");
}
