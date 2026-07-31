export type AdapterConfig = {
  mode: "synthetic" | "authoritative";
  sessionId: string;
  collectorUrl: string;
  hmacSecret: string;
  emitIntervalMs: number;
  fundingIntervalEvents: number;
  fundingScanIntervalMs: number;
  walletScanIntervalMs: number;
  walletFillLookbackMs: bigint;
  requestTimeoutMs: number;
  healthPort: number;
  hyperliquidUrls: string[];
  kaminoUrls: string[];
  kaminoLendingMarket: string;
  kaminoBorrowReserves: { asset: string; reserve: string; mint: string }[];
  phoenixUrls: string[];
  phoenixBearerToken: string;
  solanaRpcUrls: string[];
  jupiterUrls: string[];
  jupiterApiKey: string;
  sourceMaxSlotDrift: bigint;
  sourceMaxFundingAgeMs: bigint;
  paperMaximumJitoSolAtoms: bigint;
  paperNotionalUsdMicros: bigint;
  paperCollateralUsdMicros: bigint;
  paperCostsUsdMicros: bigint;
  paperRiskHaircutUsdMicros: bigint;
  paperSlippageBps: bigint;
  jitosolRewardHaircutPpm: bigint;
};

const defaultKaminoBorrowReserves = [
  "SOL:d4A2prbA2whesmvHaL88BH6Ewn5N4bTSU2Ze8P6Bc4Q:So11111111111111111111111111111111111111112",
  "JTO:9Ukd2MSw5RvVFaN8jLhWxjHLEGiF1F6Hf7v3Zq5hZsKB:jtojtomepa8beP8AuQc6eXt5FriJwfFMwQx2v2f9mCL",
].join(",");
const publicKey = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

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

function unsignedInteger(
  env: Record<string, string | undefined>,
  name: string,
  fallback: string,
  allowZero = false,
): bigint {
  const raw = env[name] ?? fallback;
  if (!/^(0|[1-9][0-9]*)$/.test(raw)) {
    throw new Error(`${name} must be a canonical unsigned integer`);
  }
  const parsed = BigInt(raw);
  if (!allowZero && parsed === 0n) throw new Error(`${name} must be positive`);
  return parsed;
}

function urls(
  env: Record<string, string | undefined>,
  name: string,
  fallback: string,
): string[] {
  const values = (env[name] ?? fallback).split(",").map((value) => value.trim());
  if (values.some((value) => value.length === 0)) {
    throw new Error(`${name} must be a comma-separated URL list`);
  }
  for (const value of values) {
    const parsed = new URL(value);
    const loopbackHttp =
      parsed.protocol === "http:" &&
      ["localhost", "127.0.0.1", "[::1]"].includes(parsed.hostname);
    if (
      (parsed.protocol !== "https:" && !loopbackHttp) ||
      parsed.username.length > 0 ||
      parsed.password.length > 0
    ) {
      throw new Error(`${name} must use HTTPS except for loopback tests`);
    }
  }
  return values;
}

function kaminoBorrowReserves(
  raw: string,
): { asset: string; reserve: string; mint: string }[] {
  const seen = new Set<string>();
  return raw.split(",").map((entry) => {
    const [asset, reserve, mint, extra] = entry.trim().split(":");
    if (
      extra !== undefined ||
      !asset ||
      !/^[A-Z0-9]{1,24}$/.test(asset) ||
      !reserve ||
      !publicKey.test(reserve) ||
      !mint ||
      !publicKey.test(mint) ||
      seen.has(asset)
    ) {
      throw new Error(
        "KAMINO_BORROW_RESERVES must contain unique ASSET:reserve:mint entries",
      );
    }
    seen.add(asset);
    return { asset, reserve, mint };
  });
}

export function loadConfig(
  env: Record<string, string | undefined> = process.env,
): AdapterConfig {
  const hmacSecret = env.ADAPTER_HMAC_SECRET ?? "";
  if (hmacSecret.length === 0) throw new Error("ADAPTER_HMAC_SECRET is required");
  const mode = env.ADAPTER_MODE ?? "synthetic";
  if (mode !== "synthetic" && mode !== "authoritative") {
    throw new Error("ADAPTER_MODE must be synthetic or authoritative");
  }
  const jupiterApiKey = env.JUPITER_API_KEY ?? "";
  const emitIntervalMs = positiveInteger(env, "EMIT_INTERVAL_MS", 10_000);
  if (
    mode === "authoritative" &&
    jupiterApiKey.length === 0 &&
    emitIntervalMs < 15_000
  ) {
    throw new Error(
      "EMIT_INTERVAL_MS must be at least 15000 for keyless Jupiter access",
    );
  }
  const sessionId = env.ADAPTER_SESSION_ID ?? `local-${Date.now()}`;
  if (!/^[a-zA-Z0-9_-]+$/.test(sessionId)) {
    throw new Error("ADAPTER_SESSION_ID must contain only letters, digits, underscores, or hyphens");
  }
  const kaminoLendingMarket =
    env.KAMINO_LENDING_MARKET ??
    "7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF";
  if (!publicKey.test(kaminoLendingMarket)) {
    throw new Error("KAMINO_LENDING_MARKET must be a base58 public key");
  }

  const paperSlippageBps = unsignedInteger(
    env,
    "PAPER_SLIPPAGE_BPS",
    "50",
    true,
  );
  if (paperSlippageBps > 10_000n) {
    throw new Error("PAPER_SLIPPAGE_BPS must be at most 10000");
  }
  const jitosolRewardHaircutPpm = unsignedInteger(
    env,
    "JITOSOL_REWARD_HAIRCUT_PPM",
    "250000",
    true,
  );
  if (jitosolRewardHaircutPpm > 1_000_000n) {
    throw new Error("JITOSOL_REWARD_HAIRCUT_PPM must be at most 1000000");
  }

  return {
    mode,
    sessionId,
    collectorUrl: env.COLLECTOR_URL ?? "http://collector:8080/v1/events",
    hmacSecret,
    emitIntervalMs,
    fundingIntervalEvents: positiveInteger(env, "FUNDING_INTERVAL_EVENTS", 12),
    fundingScanIntervalMs: positiveInteger(
      env,
      "FUNDING_SCAN_INTERVAL_MS",
      3_600_000,
    ),
    walletScanIntervalMs: positiveInteger(
      env,
      "WALLET_SCAN_INTERVAL_MS",
      60_000,
    ),
    walletFillLookbackMs: unsignedInteger(
      env,
      "WALLET_FILL_LOOKBACK_MS",
      "86400000",
    ),
    requestTimeoutMs: positiveInteger(env, "REQUEST_TIMEOUT_MS", 3000),
    healthPort: positiveInteger(env, "HEALTH_PORT", 8090),
    hyperliquidUrls: urls(
      env,
      "HYPERLIQUID_URLS",
      "https://api.hyperliquid.xyz",
    ),
    kaminoUrls: urls(
      env,
      "KAMINO_URLS",
      "https://api.kamino.finance",
    ),
    kaminoLendingMarket,
    kaminoBorrowReserves: kaminoBorrowReserves(
      env.KAMINO_BORROW_RESERVES?.trim() || defaultKaminoBorrowReserves,
    ),
    phoenixUrls: urls(
      env,
      "PHOENIX_URLS",
      "https://perp-api.phoenix.trade",
    ),
    phoenixBearerToken: env.PHOENIX_BEARER_TOKEN ?? "",
    solanaRpcUrls: urls(
      env,
      "SOLANA_RPC_URLS",
      "https://api.mainnet-beta.solana.com",
    ),
    jupiterUrls: urls(env, "JUPITER_URLS", "https://api.jup.ag/swap/v1"),
    jupiterApiKey,
    sourceMaxSlotDrift: unsignedInteger(env, "SOURCE_MAX_SLOT_DRIFT", "5000", true),
    sourceMaxFundingAgeMs: unsignedInteger(
      env,
      "SOURCE_MAX_FUNDING_AGE_MS",
      "7200000",
    ),
    paperMaximumJitoSolAtoms: unsignedInteger(
      env,
      "PAPER_MAX_JITOSOL_ATOMS",
      "10000000000",
    ),
    paperNotionalUsdMicros: unsignedInteger(
      env,
      "PAPER_NOTIONAL_USD_MICROS",
      "500000000",
    ),
    paperCollateralUsdMicros: unsignedInteger(
      env,
      "PAPER_COLLATERAL_USD_MICROS",
      "500000000",
    ),
    paperCostsUsdMicros: unsignedInteger(
      env,
      "PAPER_COSTS_USD_MICROS",
      "200000",
      true,
    ),
    paperRiskHaircutUsdMicros: unsignedInteger(
      env,
      "PAPER_RISK_HAIRCUT_USD_MICROS",
      "50000",
      true,
    ),
    paperSlippageBps,
    jitosolRewardHaircutPpm,
  };
}
