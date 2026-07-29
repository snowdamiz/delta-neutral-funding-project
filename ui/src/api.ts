import { useEffect, useState } from "react";
import type { Fixed } from "./fmt";

export type Variant = "sol_control" | "jitosol_carry";

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
  variant: Variant;
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
  state: string;
  variant: Variant;
  deltaBps: string;
  netDeltaSol: Fixed;
  perpShortSol: Fixed;
  spotQuantity: Fixed;
  marginSnapshot: MarginSnapshot;
  portfolioRunId: string;
};

export type Pnl = {
  variant: Variant;
  complete: boolean;
  portfolioRunId: string;
  basisPnlUsd: Fixed;
  netRecordedUsd: Fixed;
  tradingFeesUsd: Fixed;
  rewardAccrualUsd: Fixed;
  fundingRealizedUsd: Fixed;
};

export type Comparison = {
  mode: "independent" | "synchronized";
  complete: boolean;
  solNetRecordedUsd: Fixed;
  jitosolNetRecordedUsd: Fixed;
  jitosolIncrementalNetRecordedUsd: Fixed;
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
};

export type Opportunity = {
  id: string;
  eligible: boolean;
  variant: Variant;
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
  variant: Variant;
  status: string;
  requestedQuantity: Fixed;
  filledQuantity: Fixed;
  createdAt: string;
};

export type Fill = {
  id: string;
  portfolioRunId: string;
  variant: Variant;
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

type Page<T> = { items: T[]; limit: number; offset: number };

export type Snapshot = {
  status: Status | null;
  build: Build | null;
  config: Config | null;
  adapter: AdapterStatus | null;
  executor: ExecutorStatus | null;
  portfolios: Portfolio[];
  positions: Position[];
  pnl: Pnl[];
  comparison: Comparison[];
  decisions: RiskDecision[];
  events: RiskEvent[];
  opportunities: Opportunity[];
  orders: Order[];
  fills: Fill[];
  funding: FundingPayment[];
  capabilities: Capability[];
  buildManifestId: string;
  reconciliation: Reconciliation;
  reachable: boolean;
  polledAt: number;
};

const EMPTY: Snapshot = {
  status: null, build: null, config: null, adapter: null, executor: null,
  portfolios: [], positions: [], pnl: [], comparison: [], decisions: [], events: [],
  opportunities: [], orders: [], fills: [], funding: [], capabilities: [],
  buildManifestId: "", reconciliation: null, reachable: false, polledAt: 0,
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

export async function pull(): Promise<Snapshot> {
  const [
    status, build, config, adapter, executor, portfolios, positions, pnl,
    comparison, decisions, events, opportunities, orders, fills, funding,
    capabilities, reconciliation,
  ] = await Promise.all([
    get<Status | null>("/v1/status", null),
    get<Build | null>("/v1/build", null),
    get<Config | null>("/v1/config", null),
    get<AdapterStatus | null>("/v1/adapter/status", null),
    get<ExecutorStatus | null>("/v1/executor/status", null),
    get<Portfolio[]>("/v1/portfolios", []),
    get<Position[]>("/v1/positions", []),
    get<Pnl[]>("/v1/pnl", []),
    get<Comparison[]>("/v1/pnl/comparison", []),
    get<Page<RiskDecision> | null>("/v1/risk-decisions?limit=25", null),
    get<Page<RiskEvent> | null>("/v1/risk-events?limit=25", null),
    get<Opportunity[]>("/v1/opportunities?limit=20", []),
    get<Page<Order> | null>("/v1/orders?limit=12", null),
    get<Page<Fill> | null>("/v1/fills?limit=12", null),
    get<Page<FundingPayment> | null>("/v1/funding?limit=12", null),
    get<{ results: Capability[]; buildManifestId: string } | null>("/v1/capabilities", null),
    get<Reconciliation>("/v1/reconciliations/latest", null),
  ]);

  return {
    status, build, config, adapter, executor,
    portfolios: Array.isArray(portfolios) ? portfolios : [],
    positions: Array.isArray(positions) ? positions : [],
    pnl: Array.isArray(pnl) ? pnl : [],
    comparison: Array.isArray(comparison) ? comparison : [],
    decisions: page(decisions),
    events: page(events),
    opportunities: (Array.isArray(opportunities) ? opportunities : []).slice(0, 20),
    orders: page(orders),
    fills: page(fills),
    funding: page(funding),
    capabilities: capabilities?.results ?? [],
    buildManifestId: capabilities?.buildManifestId ?? "",
    reconciliation,
    reachable: status !== null,
    polledAt: Date.now(),
  };
}

export function useSnapshot(intervalMs = 5000): Snapshot {
  const [snap, setSnap] = useState<Snapshot>(EMPTY);

  useEffect(() => {
    let live = true;
    let timer: number;
    // Chained timeout rather than setInterval: a slow collector must not have
    // overlapping polls stacking up against it.
    const loop = async () => {
      const next = await pull();
      if (!live) return;
      setSnap(next);
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
