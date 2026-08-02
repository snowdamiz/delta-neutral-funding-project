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

export type WalletCohort = {
  version: string;
  wallets: string[];
  /** Operator-given names, by address. Absent for wallets left unnamed. */
  labels: Record<string, string>;
  maximumWallets: string;
  updatedAt: string;
};

export type WalletEntry = { wallet: string; label: string };

export type WalletFlowExitLeg = {
  legNo: number;
  reason: string;
  quantityAtoms: string;
  proceedsUsdMicros: string;
  exitedAtMs: string;
};

export type WalletFlowPosition = {
  id: string;
  wallet: string;
  mint: string;
  status: "open" | "closed";
  openedAtMs: string;
  closedAtMs: string | null;
  entryCostUsdMicros: string;
  quantityAtoms: string;
  remainingQuantityAtoms: string;
  recouped: boolean;
  peakReturnBps: string;
  migrationCrossed: boolean;
  entryMigrationStatus: string;
  exitReason: string | null;
  exitProceedsUsdMicros: string | null;
  realizedPnlUsdMicros: string | null;
  exitLegs: WalletFlowExitLeg[];
};

export type WalletFlowAction = {
  id: string;
  action: "ENTRY" | "EXIT" | "HOLD" | "SKIP";
  status: "FILLED" | "PLANNED" | "REJECTED";
  reason: string;
  processedAtMs: string;
  quantityAtoms: string;
  cashDeltaUsdMicros: string;
};

export type WalletFlowCandidate = {
  snapshotEventId: string;
  mint: string;
  wallet: string;
  observedAtMs: string;
  decision: "ENTER" | "WATCH" | "REJECT";
  reason: string;
  tokenProgram: string;
  decimals: number;
  migrationStatus: string;
  routeLabels: string[];
  marketCapUsdMicros: string;
  supplyAtoms: string;
  buyInputUsdMicros: string;
  buyOutputAtoms: string;
  sellOutputUsdMicros: string;
  entryPriceImpactBps: number;
  roundTripLossBps: number;
  exitDepthUsdMicros: string;
  topTenHolderConcentrationBps: number;
  creatorInventoryAtoms: string;
  clusterInventoryAtoms: string;
  unlinkedBuyerCount: number;
  netQuoteInflowUsdMicros: string;
  volumeUsdMicros5m: string;
  creatorSold: boolean;
  clusterSold: boolean;
  mintAuthorityDisabled: boolean;
  freezeAuthorityDisabled: boolean;
  walletScoreBps: number;
  tokenScoreBps: number;
  liquidityScoreBps: number;
  flowScoreBps: number;
  totalScoreBps: number;
};

export type TuningKnob = {
  knob: string;
  scope: "strategy" | "broker";
  label: string;
  helper: string;
  unit: "usdMicros" | "bps" | "count" | "ms" | "multiple";
  value: string;
  minimum: string;
  maximum: string;
  maxChangeBps: number;
  raisingLoosens: boolean;
  /** Already clamped to the absolute bounds: the window for THIS adjustment. */
  allowedMinimum: string;
  allowedMaximum: string;
  readyInMs: string;
};

export type TuningChange = {
  knob: string;
  previous: string;
  next: string;
  configId: string;
  reason: string;
  changedAtMs: string;
};

export type Tuning = {
  knobs: TuningKnob[];
  history: TuningChange[];
  lockedReason: string | null;
};

export type WalletFlowDiscovery = {
  wallet: string;
  runnerCount: number;
  bestRank: number;
  bestMultipleBps: string;
  alreadyFollowed: boolean;
  evidence: { mint: string; peakMultipleBps: string; buyRank: number }[];
};

export type WalletFlowLiveIntent = {
  id: string;
  kind: "ENTRY" | "EXIT";
  mint: string;
  status: "pending" | "claimed" | "filled" | "failed" | "expired";
  reason: string;
  inputUsdMicros: string;
  fractionBps: number;
  failureReason: string | null;
  createdAtMs: string;
};

export type WalletFlowLivePosition = {
  mint: string;
  status: "open" | "closed";
  remainingAtoms: string;
  costUsdMicros: string;
  proceedsUsdMicros: string;
  feeLamports: string;
  openedAtMs: string;
};

export type WalletFlow = {
  cursors: { wallet: string; captureComplete: boolean; gapReason: string | null }[];
  openMints: unknown[];
  paperAccount: {
    initialCapitalUsdMicros: string;
    reserveCapitalUsdMicros: string;
    cashBalanceUsdMicros: string;
    realizedPnlUsdMicros: string;
    updatedAtMs: string;
  } | null;
  positions: WalletFlowPosition[];
  actions: WalletFlowAction[];
  candidates: WalletFlowCandidate[];
  tuning: Tuning | null;
  strategyConfig: { id: string; values: Record<string, string> } | null;
  brokerConfig: { id: string; values: Record<string, string> } | null;
  followedWallets: WalletCohort | null;
  validation: { passed: boolean; gates: Record<string, boolean> } | null;
  discovery: WalletFlowDiscovery[];
  live: {
    mode: "paper" | "live";
    config: { id: string; values: Record<string, string> } | null;
    dailySpendUsdMicros: string;
    intents: WalletFlowLiveIntent[];
    positions: WalletFlowLivePosition[];
    fills: unknown[];
  } | null;
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

export type OperatorAction = "pause-all" | "resume" | "start" | "stop" | "arm-live" | "disarm-live";

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
  walletFlow: WalletFlow | null;
  solanaWalletConfig: WalletCohort | null;
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

const POLL_MS = 1000;

const EMPTY: Snapshot = {
  status: null, build: null, config: null, adapter: null, executor: null,
  strategies: [], portfolios: [], positions: [], pnl: [], decisions: [], events: [],
  opportunities: [], orders: [], fills: [], funding: [], fundingLeaderboard: null,
  reverseCarryLeaderboard: null, walletFlow: null,
  solanaWalletConfig: null, capabilities: [],
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
 * Strategy controls use their own bounded resource path. Collector-wide pause
 * and resume remain the emergency switch in the status banner.
 */
/**
 * A refusal that came from a database constraint arrives with its SQLSTATE
 * and padding in front of the sentence the operator needs to read.
 */
function operatorMessage(body: { message?: string } | null, fallback: string): string {
  const raw = body?.message?.trim();
  if (!raw) return fallback;
  return raw.replace(/^[A-Z0-9]{5}\s+/, "").trim() || fallback;
}

export const operatorMessageForTest = operatorMessage;

export async function control(action: OperatorAction, strategy?: string): Promise<void> {
  const path = strategy
    ? `/operator/strategies/${encodeURIComponent(strategy)}/${action}`
    : `/operator/${action}`;
  const response = await fetch(path, {
    method: "POST",
    headers: { accept: "application/json" },
  });
  if (response.ok) return;
  const error = await response.json().catch(() => null) as { message?: string } | null;
  throw new Error(operatorMessage(error, `operator request failed (${response.status})`));
}

async function configureWalletCohort(path: string, wallets: WalletEntry[]): Promise<void> {
  const response = await fetch(path, {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify({
      wallets: wallets.map(({ wallet, label }) => label ? { wallet, label } : wallet),
    }),
  });
  if (response.ok) return;
  const error = await response.json().catch(() => null) as { message?: string } | null;
  throw new Error(operatorMessage(error, `wallet update failed (${response.status})`));
}

export const configureSolanaWallets = (wallets: WalletEntry[]) =>
  configureWalletCohort("/operator/solana-wallets/config", wallets);

/** Bounds, step limit and cooldown are enforced in the database, not here. */
export async function tuneStrategy(changes: Record<string, string>): Promise<void> {
  const response = await fetch("/operator/solana-wallets/tuning", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify({ changes }),
  });
  if (response.ok) return;
  const error = await response.json().catch(() => null) as { message?: string } | null;
  throw new Error(operatorMessage(error, `tuning failed (${response.status})`));
}

export async function resetDatabase(approval: string): Promise<void> {
  const response = await fetch("/operator/reset-database", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify({ approval }),
  });
  if (response.ok) return;
  const error = await response.json().catch(() => null) as { message?: string } | null;
  throw new Error(operatorMessage(error, `database reset failed (${response.status})`));
}

export async function pull(): Promise<Snapshot> {
  const [
    status, build, config, adapter, executor, catalog, portfolios, positions, pnl,
    decisions, events, opportunities, orders, fills, funding, fundingLeaderboard,
    reverseCarryLeaderboard, walletFlow,
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
    get<WalletFlow | null>("/v1/solana-wallet-flow", null),
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
    walletFlow,
    solanaWalletConfig: walletFlow?.followedWallets ?? null,
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
