// Strategy identity comes from the collector's `/v1/strategies` catalog, never
// from a union in this file. Everything here is a lookup over that list, so a
// strategy the collector registers renders without a console change.

import type { Snapshot } from "./api";
import type { Fixed } from "./fmt";
import { diff, sum } from "./fmt";

export type Strategy = {
  id: string;
  displayName: string;
  family: string;
  legs: string[];
  benchmarkStrategyId: string | null;
  mode: string;
  controlScope: string;
  enabled: boolean;
  runState: string;
  portfolioRunIds: string[];
};

/**
 * Hued identity stops at three slots. These are the validated all-pairs
 * categorical set for this surface (worst pair CVD ΔE 9.4 deutan,
 * normal-vision 20.9) — a fourth hue cannot clear the all-pairs floors on any
 * ordering, and strategy cards are compared in any order, not just adjacent
 * ones. Slot 4+ therefore render a neutral key: identity there is the name
 * beside it, which is always present.
 */
const ACCENTS = ["var(--a1)", "var(--a2)", "var(--a3)"];

export const strategyOf = (catalog: Strategy[], id: string): Strategy | undefined =>
  catalog.find((s) => s.id === id);

/** Declared families, in catalog order. The overview facets on this. */
export const familiesOf = (catalog: Strategy[]): string[] => [
  ...new Set(catalog.map((s) => s.family)),
];

/**
 * The hue encodes *family*, not strategy. The collector registers nine
 * strategies against three validated slots, so per-strategy hues would leave
 * two thirds of the catalog grey and say nothing about how they relate.
 * Family is the grouping an operator actually reads by, and it fits the slots.
 * Within a family, identity is the name beside the key, which is always
 * present.
 * ponytail: three families fit. A fourth means faceting deeper (family →
 * sub-family), not inventing a fourth hue that fails the CVD floors.
 */
export const accentOf = (catalog: Strategy[], id: string): string => {
  const family = strategyOf(catalog, id)?.family;
  if (family === undefined) return "var(--ink3)";
  return ACCENTS[familiesOf(catalog).indexOf(family)] ?? "var(--ink3)";
};

/** Any id the data carries renders, catalogued or not. */
export const nameOf = (catalog: Strategy[], id: string): string =>
  strategyOf(catalog, id)?.displayName ?? id.replaceAll("_", " ");

/** `funding_payments` carries no strategy column; the catalog owns the mapping. */
export const ownerOf = (catalog: Strategy[], portfolioRunId: string): string =>
  catalog.find((s) => s.portfolioRunIds.includes(portfolioRunId))?.id ?? "";

type Owned = { variant?: string; portfolioRunId?: string | null };

/**
 * A row belongs to a strategy by its own variant when it carries one, otherwise
 * by the portfolio run it was recorded against. A row with neither identity is
 * collector-wide (an unattributed risk event) and is never hidden.
 */
const owns = (s: Strategy, row: Owned): boolean =>
  row.variant !== undefined
    ? row.variant === s.id
    : row.portfolioRunId
      ? s.portfolioRunIds.includes(row.portfolioRunId)
      : true;

/**
 * One strategy's slice of the snapshot. Detail views are the existing section
 * components fed a narrowed snapshot — that is the whole parameterisation.
 */
export function narrow(snap: Snapshot, s: Strategy): Snapshot {
  const keep = <T extends Owned>(rows: T[]): T[] => rows.filter((r) => owns(s, r));
  return {
    ...snap,
    portfolios: snap.portfolios.filter((p) => p.variant === s.id),
    positions: keep(snap.positions),
    pnl: keep(snap.pnl),
    decisions: keep(snap.decisions),
    events: keep(snap.events),
    opportunities: keep(snap.opportunities),
    orders: keep(snap.orders),
    fills: keep(snap.fills),
    funding: keep(snap.funding),
  };
}

/** Recorded net across every paper run a strategy owns. */
export const netOf = (snap: Snapshot, s: Strategy): Fixed =>
  sum(...snap.pnl.filter((p) => p.variant === s.id).map((p) => p.netRecordedUsd));

export type BenchmarkRow = {
  comparisonGroupId: string;
  mode: string;
  net: Fixed;
  benchmarkNet: Fixed;
  incremental: Fixed;
};

/**
 * Strategy versus its declared benchmark, per comparison group. Both sides are
 * summed from `/v1/pnl` and paired through `/v1/portfolios`, so the frame holds
 * for whatever benchmark a strategy declares — nothing here names a variant.
 */
export function benchmarkRows(snap: Snapshot, s: Strategy): BenchmarkRow[] {
  const benchmarkId = s.benchmarkStrategyId;
  if (!benchmarkId) return [];

  const netByRun = new Map(snap.pnl.map((p) => [p.portfolioRunId, p.netRecordedUsd]));
  const groups = new Map<string, { mode: string; own: Fixed[]; benchmark: Fixed[] }>();

  for (const p of snap.portfolios) {
    const side = p.variant === s.id ? "own" : p.variant === benchmarkId ? "benchmark" : null;
    if (!p.comparisonGroupId || !side) continue;
    const net = netByRun.get(p.id);
    if (!net) continue;
    const group = groups.get(p.comparisonGroupId) ?? { mode: p.comparisonMode, own: [], benchmark: [] };
    group[side].push(net);
    groups.set(p.comparisonGroupId, group);
  }

  return [...groups]
    .filter(([, g]) => g.own.length > 0 && g.benchmark.length > 0)
    .map(([comparisonGroupId, g]) => {
      const net = sum(...g.own);
      const benchmarkNet = sum(...g.benchmark);
      return {
        comparisonGroupId,
        mode: g.mode,
        net,
        benchmarkNet,
        incremental: diff(net, benchmarkNet),
      };
    })
    .sort((a, b) => a.mode.localeCompare(b.mode));
}
