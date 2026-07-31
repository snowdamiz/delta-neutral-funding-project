import { describe, expect, it } from "vitest";
import type { Snapshot } from "./api";
import type { Strategy } from "./catalog";
import { accentOf, benchmarkRows, narrow, netOf, nameOf, ownerOf } from "./catalog";
import { toDecimalString } from "./fmt";

const strategy = (over: Partial<Strategy> & { id: string }): Strategy => ({
  displayName: over.id,
  family: "carry",
  legs: [],
  benchmarkStrategyId: null,
  mode: "paper",
  controlScope: "global",
  runState: "idle",
  portfolioRunIds: [],
  ...over,
});

// A third, synthetic strategy is the Phase 0 gate: the console must render a
// strategy the collector registers without a code change here. It carries a
// benchmark, its own runs, and its own rows in every stream.
const CATALOG: Strategy[] = [
  strategy({ id: "sol_control", displayName: "SOL control", portfolioRunIds: ["local-sol-control", "local-sync-sol-control"] }),
  strategy({ id: "jitosol_carry", displayName: "JitoSOL carry", benchmarkStrategyId: "sol_control", portfolioRunIds: ["local-jitosol-carry", "local-sync-jitosol-carry"] }),
  strategy({ id: "jto_scanner", displayName: "JTO scanner", benchmarkStrategyId: "sol_control", portfolioRunIds: ["local-jto-scanner"] }),
];

const usd = (atoms: string) => ({ atoms, scale: 6 });

const pnl = (portfolioRunId: string, variant: string, net: string) => ({
  variant,
  portfolioRunId,
  complete: false,
  netRecordedUsd: usd(net),
  basisPnlUsd: usd("0"),
  tradingFeesUsd: usd("0"),
  rewardAccrualUsd: usd("0"),
  fundingRealizedUsd: usd("0"),
  borrowInterestUsd: usd("0"),
});

const portfolio = (id: string, variant: string, group: string, mode: "independent" | "synchronized") => ({
  id,
  variant,
  state: "hedged",
  comparisonGroupId: group,
  comparisonMode: mode,
  initialCapitalUsd: usd("1000000000"),
});

const SNAP = {
  strategies: CATALOG,
  portfolios: [
    portfolio("local-sol-control", "sol_control", "g:independent", "independent"),
    portfolio("local-jitosol-carry", "jitosol_carry", "g:independent", "independent"),
    portfolio("local-sync-sol-control", "sol_control", "g:synchronized", "synchronized"),
    portfolio("local-sync-jitosol-carry", "jitosol_carry", "g:synchronized", "synchronized"),
    portfolio("local-jto-scanner", "jto_scanner", "g:independent", "independent"),
  ],
  pnl: [
    pnl("local-sol-control", "sol_control", "1000000"),
    pnl("local-jitosol-carry", "jitosol_carry", "1750000"),
    pnl("local-sync-sol-control", "sol_control", "900000"),
    pnl("local-sync-jitosol-carry", "jitosol_carry", "800000"),
    pnl("local-jto-scanner", "jto_scanner", "4000000"),
  ],
  funding: [
    { id: "f1", portfolioRunId: "local-jto-scanner", effectiveAtMs: "1", normalizedRate: usd("1"), amountUsd: usd("5"), realizationStatus: "realized" },
    { id: "f2", portfolioRunId: "local-sol-control", effectiveAtMs: "2", normalizedRate: usd("1"), amountUsd: usd("6"), realizationStatus: "realized" },
  ],
  opportunities: [
    { id: "o1", eligible: true, variant: "jto_scanner", reasonCode: "positive_net_carry", observedAtMs: "3", netCarryUsdMicros: "10", expectedFundingUsdMicros: "10", navRewardUsdMicros: "0", hedgeLamports: "0" },
    { id: "o2", eligible: false, variant: "sol_control", reasonCode: "entry_gate_failed", observedAtMs: "2", netCarryUsdMicros: "-1", expectedFundingUsdMicros: "0", navRewardUsdMicros: "0", hedgeLamports: "0" },
  ],
  events: [
    { id: "e1", code: "collector_wide", message: "", severity: "warning", createdAt: "", resolvedAt: null, actionTaken: null, portfolioRunId: null },
    { id: "e2", code: "scanner_only", message: "", severity: "warning", createdAt: "", resolvedAt: null, actionTaken: null, portfolioRunId: "local-jto-scanner" },
  ],
  positions: [], decisions: [], orders: [], fills: [], capabilities: [],
  status: null, build: null, config: null, adapter: null, executor: null,
  buildManifestId: "", reconciliation: null, reachable: true, polledAt: 1,
} as unknown as Snapshot;

const scanner = CATALOG[2]!;

describe("strategy catalog", () => {
  it("renders ids the catalog never declared", () => {
    expect(nameOf(CATALOG, "jto_scanner")).toBe("JTO scanner");
    expect(nameOf(CATALOG, "drift_keeper_v2")).toBe("drift keeper v2");
    expect(accentOf(CATALOG, "drift_keeper_v2")).toBe("var(--ink3)");
  });

  // The hue encodes family, not strategy: the collector registers nine
  // strategies against three validated slots, so per-strategy hues would leave
  // two thirds of the catalog grey.
  it("assigns one hued slot per family, in catalog order, stopping at three", () => {
    const mixed = [
      strategy({ id: "a", family: "carry" }),
      strategy({ id: "b", family: "carry" }),
      strategy({ id: "c", family: "arbitrage" }),
      strategy({ id: "d", family: "signal" }),
      strategy({ id: "e", family: "a_fourth_family" }),
    ];
    expect(mixed.map((s) => accentOf(mixed, s.id))).toEqual([
      "var(--a1)", "var(--a1)", "var(--a2)", "var(--a3)", "var(--ink3)",
    ]);
  });

  it("maps a portfolio run back to its strategy", () => {
    expect(ownerOf(CATALOG, "local-jto-scanner")).toBe("jto_scanner");
    expect(ownerOf(CATALOG, "local-sync-jitosol-carry")).toBe("jitosol_carry");
    expect(ownerOf(CATALOG, "local-unknown")).toBe("");
  });

  it("narrows a snapshot to one strategy, keeping collector-wide rows", () => {
    const mine = narrow(SNAP, scanner);
    expect(mine.portfolios.map((p) => p.id)).toEqual(["local-jto-scanner"]);
    expect(mine.pnl.map((p) => p.portfolioRunId)).toEqual(["local-jto-scanner"]);
    expect(mine.funding.map((f) => f.id)).toEqual(["f1"]);
    expect(mine.opportunities.map((o) => o.id)).toEqual(["o1"]);
    // A risk event with no portfolio belongs to no strategy, so it is not hidden.
    expect(mine.events.map((e) => e.id)).toEqual(["e1", "e2"]);
  });

  it("sums recorded net across every run a strategy owns", () => {
    expect(toDecimalString(netOf(SNAP, CATALOG[1]!))).toBe("2.550000");
  });

  it("compares a strategy against its declared benchmark per group", () => {
    const rows = benchmarkRows(SNAP, CATALOG[1]!);
    expect(rows.map((r) => r.mode)).toEqual(["independent", "synchronized"]);
    expect(toDecimalString(rows[0]!.incremental)).toBe("0.750000");
    expect(toDecimalString(rows[1]!.incremental)).toBe("-0.100000");
  });

  it("compares the synthetic strategy through the same frame", () => {
    const rows = benchmarkRows(SNAP, scanner);
    expect(rows).toHaveLength(1);
    expect(toDecimalString(rows[0]!.incremental)).toBe("3.000000");
  });

  it("has nothing to compare when no benchmark is declared", () => {
    expect(benchmarkRows(SNAP, CATALOG[0]!)).toEqual([]);
  });

  // Why the detail view hands Benchmark the whole snapshot: narrowing removes
  // the benchmark's own rows, so a comparison built from a narrowed snapshot is
  // always empty. Keep this failing if someone re-narrows it.
  it("cannot compare from a narrowed snapshot", () => {
    expect(benchmarkRows(narrow(SNAP, CATALOG[1]!), CATALOG[1]!)).toEqual([]);
  });
});
