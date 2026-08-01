import { useEffect, useState } from "react";
import type { Strategy } from "./catalog";
import type { Fixed } from "./fmt";

// Strategy identity is a plain id everywhere below. The closed `Variant` union
// this file used to export is gone: the collector's `/v1/strategies` catalog is
// the only place the universe is enumerated.

export type Status = {
  activePortfolios: string;
  controlVersion: string;
  deploymentEnvironment: string;
  executionMode: string;
  leaderLeaseGeneration: string;
  leaderLeaseHolder: string | null;
  liveNotional: Fixed;
  pauseAll: boolean;
  pauseEntries: boolean;
  pauseReason: string | null;
  paused: boolean;
  shutdownRequested: boolean;
  signerReachable: boolean;
};

export type Build = {
  codeCommit: string;
  configHash: string;
  meshCommit: string;
  schemaVersion: number;
};

export type Config = Record<string, string | number | boolean> & {
  adapterMode: string;
  emitIntervalMs: number;
  liveEnabled: boolean;
  maxSourceAgeMs: number;
  expectedHoldHours: number;
  maximumBreakEvenHours: number;
  jitosolRewardHaircutPpm: number;
  minimumLiquidationDistanceBps: number;
  minimumMarginRatioPpm: number;
  rebalanceDeltaBps: number;
};

export type AdapterStatus = {
  mode: string;
  seen: boolean;
  connected: boolean;
  latest: {
    ageMs: string;
    source: string;
    eventType: string;
    sourceSlot: string;
    sourceSequence: string;
  } | null;
};

export type ExecutorStatus = {
  enabled: boolean;
  policyVersion: string;
  reachable: boolean;
  signerReachable: boolean;
};

export type Portfolio = {
  id: string;
  state: string;
  variant: string;
  comparisonGroupId: string | null;
  comparisonMode: "independent" | "synchronized";
  initialCapitalUsd: Fixed;
};

export type MarginSnapshot = {
  collateralUsd: Fixed;
  marginRatioPpm: string;
  liquidationDistanceBps: string;
  maintenanceRequirementUsd: Fixed;
};

export type Position = {
  asset?: string;
  state: string;
  variant: string;
  deltaBps: string;
  netDeltaSol: Fixed;
  perpShortSol: Fixed;
  spotQuantity: Fixed;
  marginSnapshot: MarginSnapshot | null;
  portfolioRunId: string;
};

export type Pnl = {
  variant: string;
  complete: boolean;
  portfolioRunId: string;
  basisPnlUsd: Fixed;
  netRecordedUsd: Fixed;
  tradingFeesUsd: Fixed;
  borrowInterestUsd: Fixed;
  rewardAccrualUsd: Fixed;
  fundingRealizedUsd: Fixed;
};

export type RiskDecision = {
  id: string;
  action: string;
  approved: boolean;
  createdAt: string;
  reasonCode: string;
  portfolioRunId: string;
  healthSnapshot: {
    oracleValid: boolean;
    marginRatioPpm: string;
    liquidationDistanceBps: string;
  };
};

export type RiskEvent = {
  id: string;
  code: string;
  message: string;
  severity: "critical" | "warning" | string;
  createdAt: string;
  resolvedAt: string | null;
  actionTaken: string | null;
  /** Null for collector-wide events, which belong to no single strategy. */
  portfolioRunId: string | null;
};

export type Opportunity = {
  id: string;
  eligible: boolean;
  variant: string;
  reasonCode: string;
  observedAtMs: string;
  netCarryUsdMicros: string;
  expectedFundingUsdMicros: string;
  navRewardUsdMicros: string;
  hedgeLamports: string;
};

export type Order = {
  id: string;
  intentId: string;
  intent: { leg?: string; instrument?: string } | null;
  variant: string;
  status: string;
  requestedQuantity: Fixed;
  filledQuantity: Fixed;
  createdAt: string;
};

export type Fill = {
  id: string;
  portfolioRunId: string;
  variant: string;
  quantity: Fixed;
  priceUsd: Fixed;
  feeUsd: Fixed;
  createdAt: string;
};

/** `funding_payments` carries no variant column — identity comes from the run id. */
export type FundingPayment = {
  id: string;
  portfolioRunId: string;
  effectiveAtMs: string;
  normalizedRate: Fixed;
  amountUsd: Fixed;
  realizationStatus: string;
};

export type FundingRank = {
  rank: number;
  venue: string;
  asset: string;
  instrument: string;
  fundingRatePpmPerHour: string;
  funding24hAveragePpm: string;
  fundingEmaPpm: string;
  percentilePpm: string;
  gateThresholdPpm: string;
  gateDistancePpm: string;
  samples24h: number;
  historyReady: boolean;
  depthQualified: boolean;
  eligible: boolean;
};

export type FundingLeaderboard = {
  asOfMs: string;
  historyRequiredHours: string;
  minimumSamples24h: string;
  gateThresholdPpm: string;
  items: FundingRank[];
};

export type ReverseCarryRank = {
  rank: number;
  venue: string;
  asset: string;
  instrument: string;
  observedAtMs: string;
  fundingRatePpmPerHour: string;
  funding24hAveragePpm: string;
  fundingReceiptPpmPerHour: string;
  borrowVenue: string;
  borrowMarket: string;
  borrowReserve: string;
  borrowMint: string;
  borrowSourceStatus: string;
  borrowSourceFresh: boolean;
  borrowRatePpmPerHour: string;
  borrowAvailableUsdMicros: string;
  borrowUtilizationPpm: string;
  costThresholdPpm: string;
  gateDistancePpm: string;
  samples24h: number;
  historyReady: boolean;
  depthQualified: boolean;
  eligible: boolean;
};

export type ReverseCarryLeaderboard = {
  asOfMs: string;
  historyRequiredHours: string;
  minimumSamples24h: string;
  minimumNegativeFundingPpm: string;
  maximumBorrowUtilizationPpm: string;
  maximumBreakEvenHours: string;
  costThresholdPpm: string;
  items: ReverseCarryRank[];
};

export type CrossVenueRank = {
  rank: number;
  scanId: string;
  asset: string;
  instrument: string;
  shortVenue: string;
  longVenue: string;
  realizedSpreadPpmPerHour: string;
  gateDistancePpm: string;
  historyReady: boolean;
  shortMarginStatus: string;
  longMarginStatus: string;
  shortMarginRatioPpm: string;
  longMarginRatioPpm: string;
  eligible: boolean;
};

export type CrossVenueLeaderboard = {
  asOfMs: string;
  historyRequiredHours: string;
  minimumRealizedSamples24h: string;
  gateThresholdPpm: string;
  items: CrossVenueRank[];
};

export type WalletTracking = {
  config: {
    version: string;
    wallets: string[];
    maximumWallets: string;
    updatedAt: string;
  };
  scores: {
    asOfMs: string;
    minimumDecisions: string;
    items: {
      rank: number;
      wallet: string;
      closedDecisions: string;
      netRealizedUsdMicros: string;
      feesUsdMicros: string;
      maxDrawdownUsdMicros: string;
      scorePpm: string;
      qualified: boolean;
    }[];
  };
  signals: {
    asset: string;
    observedAtMs: string;
    signalPpm: string;
    qualifiedWallets: string;
    qualified: boolean;
  }[];
  positions: unknown[];
  decisions: unknown[];
  assessment: {
    asOfMs: string;
    modes: Record<"flow" | "mirror" | "fade", {
      verdict: "pending" | "go" | "kill";
      evidenceDays: string;
      closedDecisions: string;
      netUsdMicros: string;
      riskAdjustedReturnPpm: string;
      minimumDays: string;
      minimumDecisions: string;
    }>;
    benchmarks: Record<"holdingSol" | "phase1", {
      ready: boolean;
      riskAdjustedReturnPpm: string;
    }>;
  };
};

export type Capability = {
  id: string;
  status: "implemented" | "project_local" | "deferred" | string;
  evidence: string;
};

export type Reconciliation = {
  result: string;
  differences: unknown[];
  completedAt: string;
} | null;

export type OperatorAction = "pause-all" | "resume";

type Page<T> = { items: T[]; limit: number; offset: number };

export type Snapshot = {
  status: Status | null;
  build: Build | null;
  config: Config | null;
  adapter: AdapterStatus | null;
  executor: ExecutorStatus | null;
  strategies: Strategy[];
  portfolios: Portfolio[];
  positions: Position[];
  pnl: Pnl[];
  decisions: RiskDecision[];
  events: RiskEvent[];
  opportunities: Opportunity[];
  orders: Order[];
  fills: Fill[];
  funding: FundingPayment[];
  fundingLeaderboard: FundingLeaderboard | null;
  reverseCarryLeaderboard: ReverseCarryLeaderboard | null;
  crossVenueLeaderboard: CrossVenueLeaderboard | null;
  walletTracking: WalletTracking | null;
  capabilities: Capability[];
  buildManifestId: string;
  reconciliation: Reconciliation;
  reachable: boolean;
  polledAt: number;
  /** A read is in flight right now. Rides on the snapshot so every section can
   *  show it without a second context. */
  polling: boolean;
  /** Poll cadence, so the console can show when the next read is due. */
  intervalMs: number;
};

const POLL_MS = 5000;

const EMPTY: Snapshot = {
  status: null, build: null, config: null, adapter: null, executor: null,
  strategies: [], portfolios: [], positions: [], pnl: [], decisions: [], events: [],
  opportunities: [], orders: [], fills: [], funding: [], fundingLeaderboard: null,
  reverseCarryLeaderboard: null, crossVenueLeaderboard: null, walletTracking: null, capabilities: [],
  buildManifestId: "", reconciliation: null, reachable: false, polledAt: 0,
  polling: true, intervalMs: POLL_MS,
};

async function get<T>(path: string, fallback: T): Promise<T> {
  try {
    const r = await fetch(path, { headers: { accept: "application/json" } });
    if (!r.ok) return fallback;
    const body = await r.json();
    // The collector reports real conditions as JSON error bodies (e.g. a 503
    // when it does not hold the writer lease). Those are not data.
    if (body && typeof body === "object" && "error" in body) return fallback;
    return body as T;
  } catch {
    return fallback;
  }
}

const page = <T,>(p: Page<T> | null): T[] => (Array.isArray(p?.items) ? p.items : []);

/**
 * `strategy` scopes the control to the card it was pressed from. The signing
 * proxy carries it into the operator command's reason, so the evidence trail
 * records which strategy the operator acted on even while the collector's own
 * pause state is a singleton (`controlScope: "global"` in the catalog).
 */
export async function control(action: OperatorAction, strategy?: string): Promise<void> {
  const query = strategy ? `?strategy=${encodeURIComponent(strategy)}` : "";
  const response = await fetch(`/operator/${action}${query}`, {
    method: "POST",
    headers: { accept: "application/json" },
  });
  if (response.ok) return;
  const error = await response.json().catch(() => null) as { message?: string } | null;
  throw new Error(error?.message ?? `operator request failed (${response.status})`);
}

export async function configureWallets(wallets: string[]): Promise<void> {
  const response = await fetch("/operator/wallets/config", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify({ wallets }),
  });
  if (response.ok) return;
  const error = await response.json().catch(() => null) as { message?: string } | null;
  throw new Error(error?.message ?? `wallet update failed (${response.status})`);
}

export async function resetDatabase(approval: string): Promise<void> {
  const response = await fetch("/operator/reset-database", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify({ approval }),
  });
  if (response.ok) return;
  const error = await response.json().catch(() => null) as { message?: string } | null;
  throw new Error(error?.message ?? `database reset failed (${response.status})`);
}

export async function pull(): Promise<Snapshot> {
  const [
    status, build, config, adapter, executor, catalog, portfolios, positions, pnl,
    decisions, events, opportunities, orders, fills, funding, fundingLeaderboard,
    reverseCarryLeaderboard, crossVenueLeaderboard, walletTracking,
    capabilities, reconciliation,
  ] = await Promise.all([
    get<Status | null>("/v1/status", null),
    get<Build | null>("/v1/build", null),
    get<Config | null>("/v1/config", null),
    get<AdapterStatus | null>("/v1/adapter/status", null),
    get<ExecutorStatus | null>("/v1/executor/status", null),
    get<{ strategies: Strategy[] } | null>("/v1/strategies", null),
    get<Portfolio[]>("/v1/portfolios", []),
    get<Position[]>("/v1/positions", []),
    get<Pnl[]>("/v1/pnl", []),
    get<Page<RiskDecision> | null>("/v1/risk-decisions?limit=25", null),
    get<Page<RiskEvent> | null>("/v1/risk-events?limit=25", null),
    get<Opportunity[]>("/v1/opportunities", []),
    get<Page<Order> | null>("/v1/orders?limit=12", null),
    get<Page<Fill> | null>("/v1/fills?limit=12", null),
    get<Page<FundingPayment> | null>("/v1/funding?limit=12", null),
    get<FundingLeaderboard | null>("/v1/funding/leaderboard", null),
    get<ReverseCarryLeaderboard | null>("/v1/reverse-carry/leaderboard", null),
    get<CrossVenueLeaderboard | null>("/v1/cross-venue/leaderboard", null),
    get<WalletTracking | null>("/v1/wallets", null),
    get<{ results: Capability[]; buildManifestId: string } | null>("/v1/capabilities", null),
    get<Reconciliation>("/v1/reconciliations/latest", null),
  ]);

  return {
    status, build, config, adapter, executor,
    strategies: Array.isArray(catalog?.strategies) ? catalog.strategies : [],
    portfolios: Array.isArray(portfolios) ? portfolios : [],
    positions: Array.isArray(positions) ? positions : [],
    pnl: Array.isArray(pnl) ? pnl : [],
    decisions: page(decisions),
    events: page(events),
    opportunities: Array.isArray(opportunities) ? opportunities : [],
    orders: page(orders),
    fills: page(fills),
    funding: page(funding),
    fundingLeaderboard,
    reverseCarryLeaderboard,
    crossVenueLeaderboard,
    walletTracking,
    capabilities: capabilities?.results ?? [],
    buildManifestId: capabilities?.buildManifestId ?? "",
    reconciliation,
    reachable: status !== null,
    polledAt: Date.now(),
    polling: false,
    intervalMs: POLL_MS,
  };
}

export function useSnapshot(intervalMs = POLL_MS): Snapshot {
  const [snap, setSnap] = useState<Snapshot>(EMPTY);

  useEffect(() => {
    let live = true;
    let timer: number;
    // Chained timeout rather than setInterval: a slow collector must not have
    // overlapping polls stacking up against it.
    const loop = async () => {
      setSnap((current) => ({ ...current, polling: true }));
      const next = await pull();
      if (!live) return;
      setSnap({ ...next, intervalMs });
      timer = window.setTimeout(loop, intervalMs);
    };
    void loop();
    return () => {
      live = false;
      window.clearTimeout(timer);
    };
  }, [intervalMs]);

  return snap;
}
