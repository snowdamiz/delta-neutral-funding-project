export type AdapterConfig = {
  collectorUrl: string;
  hmacSecret: string;
  emitIntervalMs: number;
  requestTimeoutMs: number;
  healthPort: number;
};

function positiveInteger(
  env: Record<string, string | undefined>,
  name: string,
  fallback: number,
): number {
  const raw = env[name] ?? String(fallback);
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

export function loadConfig(
  env: Record<string, string | undefined> = process.env,
): AdapterConfig {
  const hmacSecret = env.ADAPTER_HMAC_SECRET ?? "";
  if (hmacSecret.length === 0) throw new Error("ADAPTER_HMAC_SECRET is required");

  return {
    collectorUrl: env.COLLECTOR_URL ?? "http://collector:8080/v1/events",
    hmacSecret,
    emitIntervalMs: positiveInteger(env, "EMIT_INTERVAL_MS", 5000),
    requestTimeoutMs: positiveInteger(env, "REQUEST_TIMEOUT_MS", 3000),
    healthPort: positiveInteger(env, "HEALTH_PORT", 8090),
  };
}
