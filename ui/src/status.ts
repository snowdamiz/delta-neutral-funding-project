// One derivation of "what is the system doing right now", shared by the sticky
// header pill and the overview banner. Two places rendered it slightly
// differently before; a status that disagrees with itself is worse than no
// status at all.

import type { Snapshot } from "./api";
import { nameOf } from "./catalog";
import { age, fmt, micros, num } from "./fmt";
import type { Tone } from "./ui";

export type Health = {
  word: string;
  tone: Tone;
  /** One plain sentence: what is happening and what it means. */
  detail: string;
  /** Second line, only when the first needs qualifying. */
  extra: string;
  paused: boolean;
  /** Paper controls exist only for a local paper deployment. */
  controllable: boolean;
  openAlerts: number;
  criticalAlerts: number;
};

export function health(snap: Snapshot): Health {
  const s = snap.status;
  const open = snap.events.filter((e) => !e.resolvedAt);
  const alerts = {
    openAlerts: open.length,
    criticalAlerts: open.filter((e) => e.severity === "critical").length,
  };

  if (!s) {
    return {
      word: "Offline",
      tone: "crit",
      detail: "The console cannot reach the collector, so nothing below is current.",
      extra: "Start the stack with `docker compose up`, then this reconnects on its own.",
      paused: false,
      controllable: false,
      ...alerts,
    };
  }

  const paused = s.paused || s.pauseAll || s.pauseEntries;
  const controllable = s.deploymentEnvironment === "local" && s.executionMode === "paper";
  const ageMs = Number(snap.adapter?.latest?.ageMs ?? NaN);
  const maxAge = Number(snap.config?.maxSourceAgeMs ?? 60000);
  const stale = Number.isFinite(ageMs) && ageMs > maxAge;

  if (paused) {
    const lease = s.pauseReason === "leader_lease_lost";
    return {
      word: "Stopped",
      tone: lease ? "crit" : "warn",
      detail: `No new positions will be opened — reason: ${s.pauseReason ?? "unspecified"}.`,
      extra: lease
        ? `The writer lease is held by ${s.leaderLeaseHolder ?? "nobody"} at generation ${s.leaderLeaseGeneration}. No instance is authoritative, so every entry fails closed.`
        : "Positions already open are still tracked and still settle funding.",
      paused,
      controllable,
      ...alerts,
    };
  }

  if (stale) {
    return {
      word: "Stale",
      tone: "warn",
      detail: `Market data is ${age(ageMs)} old against a ${num(maxAge / 1000)}s freshness limit.`,
      extra: "Entries gate off automatically until a fresh snapshot arrives — this is the system protecting itself.",
      paused,
      controllable,
      ...alerts,
    };
  }

  if (Number(s.activePortfolios) > 0) {
    return {
      word: "Running",
      tone: "ok",
      detail: `${num(s.activePortfolios)} portfolio(s) are holding positions and accruing funding.`,
      extra: "",
      paused,
      controllable,
      ...alerts,
    };
  }

  const latest = snap.opportunities[0];
  return {
    word: "Waiting",
    tone: "ok",
    detail: "Everything is healthy — no market currently clears the profitability gate, so nothing is open.",
    extra: latest
      ? `Most recent evaluation: ${nameOf(snap.strategies, latest.variant)} projected ${fmt(micros(latest.netCarryUsdMicros), 4, { signed: true })} USD net over ${num(snap.config?.expectedHoldHours ?? 72)}h after costs.`
      : "No market has been evaluated yet.",
    paused,
    controllable,
    ...alerts,
  };
}
