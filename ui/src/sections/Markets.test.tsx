import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { Snapshot } from "../api";
import { Markets } from "./Markets";

describe("market scans", () => {
  it("renders ranked funding, EMA, and gate distance", () => {
    const snap = {
      fundingLeaderboard: {
        asOfMs: "1785024000000",
        historyRequiredHours: "168",
        minimumSamples24h: "24",
        gateThresholdPpm: "7",
        items: [{
          rank: 1,
          venue: "hyperliquid",
          asset: "BTC",
          instrument: "BTC-PERP",
          fundingRatePpmPerHour: "20",
          funding24hAveragePpm: "18",
          fundingEmaPpm: "19",
          percentilePpm: "1000000",
          gateThresholdPpm: "7",
          gateDistancePpm: "11",
          samples24h: 24,
          historyReady: true,
          depthQualified: true,
          eligible: true,
        }],
      },
    } as Snapshot;

    const html = renderToStaticMarkup(<Markets snap={snap} />);
    expect(html).toContain("BTC");
    expect(html).toContain("+20");
    expect(html).toContain("+19");
    expect(html).toContain("+11");
    expect(html).toContain("clears gate");
  });

  it("distinguishes an untradeable route from history warm-up", () => {
    const snap = {
      fundingLeaderboard: {
        gateThresholdPpm: "7",
        items: [{
          rank: 1,
          venue: "hyperliquid",
          asset: "BTC",
          fundingRatePpmPerHour: "20",
          funding24hAveragePpm: "20",
          fundingEmaPpm: "20",
          gateDistancePpm: "13",
          samples24h: 1,
          historyReady: false,
          depthQualified: false,
          eligible: false,
        }],
      },
    } as Snapshot;

    expect(renderToStaticMarkup(<Markets snap={snap} />))
      .toContain("no executable route");
  });

  it("renders negative funding against live borrow economics", () => {
    const snap = {
      fundingLeaderboard: null,
      reverseCarryLeaderboard: {
        asOfMs: "1785024000000",
        historyRequiredHours: "168",
        minimumSamples24h: "24",
        minimumNegativeFundingPpm: "10",
        maximumBorrowUtilizationPpm: "950000",
        maximumBreakEvenHours: "48",
        costThresholdPpm: "2",
        items: [{
          rank: 1,
          venue: "hyperliquid",
          asset: "SOL",
          instrument: "SOL-PERP",
          observedAtMs: "1785024000000",
          fundingRatePpmPerHour: "-22",
          funding24hAveragePpm: "-20",
          fundingReceiptPpmPerHour: "20",
          borrowVenue: "kamino",
          borrowMarket: "market",
          borrowReserve: "reserve",
          borrowMint: "mint",
          borrowSourceStatus: "valid",
          borrowSourceFresh: true,
          borrowRatePpmPerHour: "5",
          borrowAvailableUsdMicros: "600000000",
          borrowUtilizationPpm: "400000",
          costThresholdPpm: "2",
          gateDistancePpm: "13",
          samples24h: 24,
          historyReady: true,
          depthQualified: true,
          eligible: true,
        }],
      },
    } as Snapshot;

    const html = renderToStaticMarkup(<Markets snap={snap} />);
    expect(html).toContain("Reverse carry");
    expect(html).toContain("kamino");
    expect(html).toContain("-20");
    expect(html).toContain("5");
    expect(html).toContain("+13");
  });
});
