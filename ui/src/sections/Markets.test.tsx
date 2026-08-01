import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { Snapshot } from "../api";
import { Markets, SolanaWalletConfig, WalletConfig } from "./Markets";

describe("market scans", () => {
  it("edits the live wallet cohort without environment variables", () => {
    const html = renderToStaticMarkup(
      <WalletConfig config={{
        version: "4",
        wallets: ["0x1111111111111111111111111111111111111111"],
        maximumWallets: "50",
        updatedAt: "2026-07-30T12:00:00Z",
      }} />,
    );

    expect(html).toContain("Hyperliquid wallets");
    expect(html).toContain("0x1111111111111111111111111111111111111111");
    expect(html).toContain("Save cohort");
    expect(html).not.toContain("HYPERLIQUID_WALLETS");
  });

  it("adds and removes followed Solana wallets on the fly", () => {
    const wallet = "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";
    const html = renderToStaticMarkup(
      <SolanaWalletConfig config={{
        version: "3",
        wallets: [wallet],
        maximumWallets: "100",
        updatedAt: "2026-08-01T12:00:00Z",
      }} />,
    );

    expect(html).toContain("Follow wallet");
    expect(html).toContain(wallet);
    expect(html).toContain("Remove");
    expect(html).toContain("1/100 followed");
  });

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

  it("renders realized cross-venue spread and independent margin state", () => {
    const snap = {
      fundingLeaderboard: null,
      reverseCarryLeaderboard: null,
      crossVenueLeaderboard: {
        asOfMs: "1785024000000",
        historyRequiredHours: "168",
        minimumRealizedSamples24h: "24",
        gateThresholdPpm: "7",
        items: [{
          rank: 1,
          scanId: "scan-1",
          asset: "BTC",
          instrument: "BTC-PERP",
          shortVenue: "hyperliquid",
          longVenue: "venue_low",
          realizedSpreadPpmPerHour: "30",
          gateDistancePpm: "23",
          historyReady: true,
          shortMarginStatus: "valid",
          longMarginStatus: "valid",
          shortMarginRatioPpm: "40000000",
          longMarginRatioPpm: "20000000",
          eligible: true,
        }],
      },
    } as Snapshot;

    const html = renderToStaticMarkup(<Markets snap={snap} />);
    expect(html).toContain("Cross-venue spread");
    expect(html).toContain("hyperliquid");
    expect(html).toContain("venue_low");
    expect(html).toContain("+30");
    expect(html).toContain("+23");
    expect(html).toContain("20.00×");
  });

  it("renders look-ahead-safe wallet scores and the paper gate", () => {
    const snap = {
      fundingLeaderboard: null,
      reverseCarryLeaderboard: null,
      crossVenueLeaderboard: null,
      walletTracking: {
        scores: {
          asOfMs: "1785024000000",
          minimumDecisions: "20",
          items: [{
            rank: 1,
            wallet: "0x1111111111111111111111111111111111111111",
            closedDecisions: "24",
            netRealizedUsdMicros: "12000000",
            feesUsdMicros: "1000000",
            maxDrawdownUsdMicros: "3000000",
            scorePpm: "2750000",
            qualified: true,
          }],
        },
        signals: [{
          asset: "BTC",
          observedAtMs: "1785024000000",
          signalPpm: "500000",
          qualifiedWallets: "1",
          qualified: true,
        }],
        positions: [],
        decisions: [],
        assessment: {
          asOfMs: "1785024000000",
          modes: {
            flow: {
              verdict: "pending",
              evidenceDays: "32",
              closedDecisions: "12",
              netUsdMicros: "1000000",
              riskAdjustedReturnPpm: "900",
              minimumDays: "60",
              minimumDecisions: "20",
            },
            mirror: {
              verdict: "pending",
              evidenceDays: "32",
              closedDecisions: "12",
              netUsdMicros: "1000000",
              riskAdjustedReturnPpm: "900",
              minimumDays: "60",
              minimumDecisions: "20",
            },
            fade: {
              verdict: "pending",
              evidenceDays: "32",
              closedDecisions: "0",
              netUsdMicros: "0",
              riskAdjustedReturnPpm: "0",
              minimumDays: "60",
              minimumDecisions: "20",
            },
          },
          benchmarks: {
            holdingSol: { ready: false, riskAdjustedReturnPpm: "0" },
            phase1: { ready: false, riskAdjustedReturnPpm: "0" },
          },
        },
      },
    } as unknown as Snapshot;

    const html = renderToStaticMarkup(<Markets snap={snap} />);
    expect(html).toContain("Wallet consistency");
    expect(html).toContain("0x1111…1111");
    expect(html).toContain("24");
    expect(html).toContain("275.00%");
    expect(html).toContain("+12.00");
    expect(html).toContain("32/60 days");
  });
});
