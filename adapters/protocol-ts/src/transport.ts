import { createHmac } from "node:crypto";
import { type MarketSnapshotEvent, validateEvent } from "./contracts.js";

export function signBody(secret: string, body: string): string {
  if (secret.length === 0) throw new Error("ADAPTER_HMAC_SECRET is required");
  return createHmac("sha256", secret).update(body).digest("hex");
}

export async function postEvent(
  url: string,
  secret: string,
  event: MarketSnapshotEvent,
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
