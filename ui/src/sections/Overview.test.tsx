import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { Snapshot } from "../api";
import { Overview } from "./Overview";

describe("strategy evaluation states", () => {
  it("reports missing external configuration instead of claiming no evaluation", () => {
    const strategy = (id: string, family: string, enabled: boolean) => ({
      id,
      displayName: id,
      family,
      legs: ["paper"],
      benchmarkStrategyId: null,
      mode: "paper",
      controlScope: "strategy",
      enabled,
      runState: "idle",
      portfolioRunIds: [],
    });
    const snap = {
      strategies: [
        strategy("cross_venue_funding", "arbitrage", false),
        strategy("hyperliquid_wallet_flow", "signal", false),
      ],
      opportunities: [],
      portfolios: [],
      pnl: [],
      events: [],
      crossVenueLeaderboard: { items: [] },
      walletTracking: { config: { wallets: [] }, scores: { items: [] } },
      status: { deploymentEnvironment: "local", executionMode: "paper" },
    } as unknown as Snapshot;

    const html = renderToStaticMarkup(
      <Overview snap={snap} onOpen={() => undefined} onManageWallets={() => undefined} />,
    );
    expect(html).toContain("venue unavailable");
    expect(html).toContain("wallets not configured");
    expect(html).not.toContain("not evaluated");
    expect(html).toContain("Start strategy");
    expect(html).toContain("Configure wallets before starting.");
    expect(html).toContain("Manage wallets →");
    expect(html).not.toContain("Stop strategy");
  });
});
