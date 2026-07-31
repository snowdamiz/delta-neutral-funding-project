import { createHmac } from "node:crypto";
import { type ProtocolEvent, validateEvent } from "./contracts.js";

const walletAddress = /^0x[0-9a-f]{40}$/;

export type WalletConfig = {
  version: string;
  wallets: string[];
};

export function signBody(secret: string, body: string): string {
  if (secret.length === 0) throw new Error("ADAPTER_HMAC_SECRET is required");
  return createHmac("sha256", secret).update(body).digest("hex");
}

export async function postEvent(
  url: string,
  secret: string,
  event: ProtocolEvent,
  timeoutMs: number,
): Promise<Response> {
  const body = JSON.stringify(validateEvent(event));
  return fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-adapter-signature": signBody(secret, body),
    },
    body,
    signal: AbortSignal.timeout(timeoutMs),
  });
}

export async function fetchWalletConfig(
  eventsUrl: string,
  timeoutMs: number,
): Promise<WalletConfig> {
  const url = new URL("/v1/wallets/config", eventsUrl);
  const response = await fetch(url, {
    headers: { accept: "application/json" },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) {
    throw new Error(`wallet config returned ${response.status}`);
  }
  const body = await response.json() as { version?: unknown; wallets?: unknown };
  const wallets = body.wallets;
  if (
    typeof body.version !== "string" ||
    !/^(0|[1-9][0-9]*)$/.test(body.version) ||
    !Array.isArray(wallets) ||
    wallets.length > 50 ||
    wallets.some((wallet) => typeof wallet !== "string" || !walletAddress.test(wallet)) ||
    new Set(wallets).size !== wallets.length
  ) {
    throw new Error("collector returned an invalid wallet config");
  }
  return { version: body.version, wallets };
}
