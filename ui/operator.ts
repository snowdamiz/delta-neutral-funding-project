import { createHmac } from "node:crypto";
export { approvedDatabaseReset } from "./reset";

/**
 * Sign the bounded collector controls the browser may reach. The one local
 * database reset never reaches the collector and is guarded separately.
 *
 * `?strategy=<id>` names the card the control was pressed from. The collector's
 * pause state is a singleton, so the scope does not change what the command
 * does — it goes into the reason, which `operator_commands` persists, so the
 * evidence trail answers "which strategy was the operator acting on?". The
 * signature covers the body, so the scope cannot be edited in flight.
 */
export function operatorRequest(
  url: string | undefined,
  secret: string,
  key: string,
  requestBody = "",
) {
  const [path, query] = (url ?? "").split("?", 2);
  if (path === "/operator/wallets/config" || path === "/v1/wallets/config") {
    try {
      const parsed = JSON.parse(requestBody) as { wallets?: unknown };
      if (
        !parsed ||
        typeof parsed !== "object" ||
        Object.keys(parsed).length !== 1 ||
        !Array.isArray(parsed.wallets) ||
        parsed.wallets.length > 50
      ) return null;
      const wallets = parsed.wallets.map((wallet) =>
        typeof wallet === "string" ? wallet.trim().toLowerCase() : "",
      );
      if (
        wallets.some((wallet) => !/^0x[0-9a-f]{40}$/.test(wallet)) ||
        new Set(wallets).size !== wallets.length
      ) return null;
      return signed(JSON.stringify({
        reason: "wallet cohort updated from local operator console",
        wallets,
      }), secret, key);
    } catch {
      return null;
    }
  }
  const action =
    path === "/operator/pause-all" || path === "/v1/pause-all"
      ? "pause-all"
      : path === "/operator/resume" || path === "/v1/resume"
        ? "resume"
        : null;
  if (!action) return null;

  const strategy = new URLSearchParams(query ?? "").get("strategy") ?? "";
  const verb = action === "resume" ? "started" : "stopped";
  // Unrecognised scopes are dropped, not passed through: the reason is operator
  // evidence, not a free-text channel from the browser.
  const scoped = /^[a-z0-9_]{1,64}$/.test(strategy);
  const body = JSON.stringify({
    reason: `${verb} from local operator console${scoped ? ` (strategy: ${strategy})` : ""}`,
    ...(scoped ? { strategy } : {}),
  });
  return signed(body, secret, key);
}

function signed(body: string, secret: string, key: string) {
  return {
    body,
    headers: {
      "content-type": "application/json",
      "content-length": Buffer.byteLength(body).toString(),
      "x-idempotency-key": key,
      "x-operator-signature": createHmac("sha256", secret).update(`${key}\n${body}`).digest("hex"),
    },
  };
}
