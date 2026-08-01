import { describe, expect, it } from "vitest";
import type { Snapshot, Status } from "./api";
import { parseRoute } from "./App";
import { health } from "./status";

const status = (over: Partial<Status> = {}): Status => ({
  activePortfolios: "0",
  controlVersion: "0",
  deploymentEnvironment: "local",
  executionMode: "paper",
  leaderLeaseGeneration: "4",
  leaderLeaseHolder: "collector-local-1",
  liveNotional: { atoms: "0", scale: 6 },
  pauseAll: false,
  pauseEntries: false,
  pauseReason: "",
  paused: false,
  shutdownRequested: false,
  signerReachable: false,
  ...over,
});

const snap = (over: Partial<Snapshot> = {}): Snapshot =>
  ({
    status: status(),
    config: { maxSourceAgeMs: 60000, expectedHoldHours: 72 },
    adapter: { latest: { ageMs: "1000" } },
    strategies: [],
    opportunities: [],
    events: [],
    portfolios: [],
    pnl: [],
    ...over,
  }) as unknown as Snapshot;

describe("system state", () => {
  it("is offline when the collector does not answer", () => {
    const h = health(snap({ status: null }));
    expect(h.word).toBe("Offline");
    expect(h.tone).toBe("crit");
    expect(h.controllable).toBe(false);
  });

  it("is critical, not merely stopped, when the writer lease is lost", () => {
    const h = health(snap({ status: status({ paused: true, pauseReason: "leader_lease_lost" }) }));
    expect(h.word).toBe("Stopped");
    expect(h.tone).toBe("crit");
    expect(h.extra).toContain("fails closed");
  });

  it("warns rather than alarms on an operator pause", () => {
    const h = health(snap({ status: status({ pauseAll: true, pauseReason: "operator" }) }));
    expect(h.word).toBe("Stopped");
    expect(h.tone).toBe("warn");
    expect(h.paused).toBe(true);
  });

  // A pause outranks stale data: the operator's reason is the useful one.
  it("reports a feed older than the pinned limit as stale", () => {
    const h = health(snap({ adapter: { latest: { ageMs: "90000" } } as never }));
    expect(h.word).toBe("Stale");
    expect(h.tone).toBe("warn");
  });

  it("separates holding positions from healthily waiting for one", () => {
    expect(health(snap({ status: status({ activePortfolios: "2" }) })).word).toBe("Running");
    const waiting = health(snap());
    expect(waiting.word).toBe("Waiting");
    expect(waiting.tone).toBe("ok");
  });

  it("counts unresolved alerts and flags the critical ones", () => {
    const events = [
      { id: "a", severity: "critical", resolvedAt: null },
      { id: "b", severity: "warning", resolvedAt: null },
      { id: "c", severity: "critical", resolvedAt: "2026-07-30T00:00:00Z" },
    ] as never;
    const h = health(snap({ events }));
    expect(h.openAlerts).toBe(2);
    expect(h.criticalAlerts).toBe(1);
  });

  it("offers paper controls only for a local paper deployment", () => {
    expect(health(snap()).controllable).toBe(true);
    expect(health(snap({ status: status({ executionMode: "live" }) })).controllable).toBe(false);
    expect(health(snap({ status: status({ deploymentEnvironment: "prod" }) })).controllable).toBe(false);
  });
});

describe("routing", () => {
  it("resolves pages, strategies, and anything unrecognised", () => {
    expect(parseRoute("")).toEqual({ tab: "", strategy: "", sub: "" });
    expect(parseRoute("#/markets")).toEqual({ tab: "markets", strategy: "", sub: "" });
    expect(parseRoute("#/system")).toEqual({ tab: "system", strategy: "", sub: "" });
    expect(parseRoute("#/s/jitosol_carry")).toEqual({ tab: "", strategy: "jitosol_carry", sub: "" });
    // A stale link from the previous console, and an invented one, land home.
    expect(parseRoute("#jitosol_carry")).toEqual({ tab: "", strategy: "", sub: "" });
    expect(parseRoute("#/nonsense")).toEqual({ tab: "", strategy: "", sub: "" });
  });

  it("resolves a strategy sub-tab and drops one it does not own", () => {
    expect(parseRoute("#/s/jitosol_carry/risk")).toEqual({
      tab: "", strategy: "jitosol_carry", sub: "risk",
    });
    expect(parseRoute("#/s/jitosol_carry/nonsense")).toEqual({
      tab: "", strategy: "jitosol_carry", sub: "",
    });
  });
});
