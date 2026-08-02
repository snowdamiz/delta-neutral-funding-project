import { createHmac } from "node:crypto";
export { approvedDatabaseReset } from "./reset";

/**
 * Sign the bounded collector controls the browser may reach. The one local
 * database reset never reaches the collector and is guarded separately.
 *
 * Strategy identity is part of the bounded path and the signature covers the
 * generated reason body, so neither can become a browser-controlled text
 * channel.
 */
export function operatorRequest(
  url: string | undefined,
  secret: string,
  key: string,
  requestBody = "",
) {
  const [path] = (url ?? "").split("?", 2);
  if (path === "/operator/solana-wallets/config" || path === "/v1/solana-wallet-flow/config") {
    try {
      const parsed = JSON.parse(requestBody) as { wallets?: unknown };
      if (
        !parsed ||
        typeof parsed !== "object" ||
        Object.keys(parsed).length !== 1 ||
        !Array.isArray(parsed.wallets) ||
        parsed.wallets.length > 100
      ) return null;
      // A wallet is an address, optionally named. The proxy rebuilds each
      // entry field by field, so nothing the browser sends reaches the
      // collector except an address and a label of bounded, single-line text.
      const entries = parsed.wallets.map((entry) => {
        if (typeof entry === "string") return { wallet: entry.trim(), label: "" };
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null;
        const { wallet, label, ...rest } = entry as Record<string, unknown>;
        if (Object.keys(rest).length > 0) return null;
        if (typeof wallet !== "string") return null;
        if (label !== undefined && typeof label !== "string") return null;
        return { wallet: wallet.trim(), label: (label ?? "").trim() };
      });
      if (entries.some((entry) => entry === null)) return null;
      const clean = entries as { wallet: string; label: string }[];
      if (
        clean.some(({ wallet, label }) =>
          !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(wallet)
          || label.length > 40
          || /[\n\r\t]/.test(label)) ||
        new Set(clean.map(({ wallet }) => wallet)).size !== clean.length
      ) return null;
      return signed(JSON.stringify({
        reason: "Solana wallet cohort updated from local operator console",
        wallets: clean.map(({ wallet, label }) => label ? { wallet, label } : wallet),
      }), secret, key);
    } catch {
      return null;
    }
  }
  const strategyControl = path?.match(
    /^\/(?:operator|v1)\/strategies\/([a-z0-9_]{1,64})\/(start|stop)$/,
  );
  if (strategyControl) {
    const [, strategy, action] = strategyControl;
    return signed(JSON.stringify({
      reason: `${action === "start" ? "started" : "stopped"} from local operator console (strategy: ${strategy})`,
    }), secret, key);
  }

  // Live arm/disarm: the proxy generates the entire body, including the
  // approval literal, so the browser can neither weaken nor invent it.
  const strategyMode = path?.match(
    /^\/operator\/strategies\/([a-z0-9_]{1,64})\/(arm-live|disarm-live)$/,
  );
  if (strategyMode) {
    const [, strategy, action] = strategyMode;
    const live = action === "arm-live";
    return signed(JSON.stringify({
      mode: live ? "live" : "paper",
      ...(live ? { approval: "ARM LIVE TRADING" } : {}),
      reason: `${live ? "armed live trading" : "disarmed live trading"} from local operator console (strategy: ${strategy})`,
    }), secret, key, `/v1/strategies/${strategy}/mode`);
  }

  const action =
    path === "/operator/pause-all" || path === "/v1/pause-all"
      ? "pause-all"
      : path === "/operator/resume" || path === "/v1/resume"
        ? "resume"
        : null;
  if (!action) return null;

  const verb = action === "resume" ? "started" : "stopped";
  const body = JSON.stringify({
    reason: `${verb} from local operator console`,
  });
  return signed(body, secret, key);
}

function signed(body: string, secret: string, key: string, forwardPath?: string) {
  return {
    body,
    ...(forwardPath === undefined ? {} : { forwardPath }),
    headers: {
      "content-type": "application/json",
      "content-length": Buffer.byteLength(body).toString(),
      "x-idempotency-key": key,
      "x-operator-signature": createHmac("sha256", secret).update(`${key}\n${body}`).digest("hex"),
    },
  };
}
