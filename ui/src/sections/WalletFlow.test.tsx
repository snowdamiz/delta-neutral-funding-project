import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { Snapshot, WalletFlow as WalletFlowState } from "../api";
import { LiveControl, SolanaWalletConfig, WalletFlow } from "./WalletFlow";

const FLOW: WalletFlowState = {
  cursors: [{ wallet: "11111111111111111111111111111111", captureComplete: true, gapReason: null }],
  openMints: [{
    acquisition: { eventId: "acq-1" },
    snapshotEventId: "snap-1c",
    snapshotObservedAtMs: "1785023500000",
    decision: "ENTER",
    reason: "ELIGIBLE",
    configId: "solana-wallet-flow-v2",
  }],
  paperAccount: {
    initialCapitalUsdMicros: "1000000000",
    reserveCapitalUsdMicros: "300000000",
    cashBalanceUsdMicros: "998979999",
    realizedPnlUsdMicros: "98979999",
    updatedAtMs: "1785024000000",
  },
  positions: [{
    id: "solana-paper:acq-1",
    wallet: "11111111111111111111111111111111",
    mint: "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
    status: "open",
    openedAtMs: "1785023000000",
    closedAtMs: null,
    entryCostUsdMicros: "100520000",
    quantityAtoms: "2475000",
    remainingQuantityAtoms: "1469600",
    recouped: true,
    peakReturnBps: "24870",
    migrationCrossed: true,
    entryMigrationStatus: "pre_migration",
    exitReason: null,
    exitProceedsUsdMicros: null,
    realizedPnlUsdMicros: null,
    exitLegs: [{
      legNo: 1, reason: "RECOUP", quantityAtoms: "1005400",
      proceedsUsdMicros: "100519999", exitedAtMs: "1785023500000",
    }],
  }, {
    id: "solana-paper:acq-2",
    wallet: "11111111111111111111111111111111",
    mint: "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiK",
    status: "closed",
    openedAtMs: "1785020000000",
    closedAtMs: "1785021000000",
    entryCostUsdMicros: "100520000",
    quantityAtoms: "2475000",
    remainingQuantityAtoms: "0",
    recouped: false,
    peakReturnBps: "10100",
    migrationCrossed: false,
    entryMigrationStatus: "pre_migration",
    exitReason: "TIME_STOP_FLAT",
    exitProceedsUsdMicros: "99970000",
    realizedPnlUsdMicros: "-550000",
    exitLegs: [],
  }],
  actions: [{
    id: "snap-1c:paper",
    action: "EXIT",
    status: "FILLED",
    reason: "RECOUP",
    processedAtMs: "1785023500000",
    quantityAtoms: "1005400",
    cashDeltaUsdMicros: "100519999",
  }],
  candidates: [{
    snapshotEventId: "snap-1c",
    mint: "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ",
    wallet: "11111111111111111111111111111111",
    observedAtMs: "1785023500000",
    decision: "REJECT",
    reason: "TOP_TEN_CONCENTRATION",
    tokenProgram: "token-2022",
    decimals: 6,
    migrationStatus: "pre_migration",
    routeLabels: ["Pump.fun", "HumidiFi"],
    marketCapUsdMicros: "412000000000",
    supplyAtoms: "1000000000000000",
    buyInputUsdMicros: "100000000",
    buyOutputAtoms: "2475000",
    sellOutputUsdMicros: "99280000",
    entryPriceImpactBps: 96,
    roundTripLossBps: 720,
    exitDepthUsdMicros: "1400000000",
    topTenHolderConcentrationBps: 7401,
    creatorInventoryAtoms: "102015652111205",
    clusterInventoryAtoms: "102015652111205",
    unlinkedBuyerCount: 24,
    netQuoteInflowUsdMicros: "8400000",
    volumeUsdMicros5m: "42000000",
    creatorSold: false,
    clusterSold: false,
    mintAuthorityDisabled: true,
    freezeAuthorityDisabled: true,
    walletScoreBps: 5000,
    tokenScoreBps: 2500,
    liquidityScoreBps: 8000,
    flowScoreBps: 6000,
    totalScoreBps: 5375,
  }],
  strategyConfig: {
    id: "solana-wallet-flow-v2",
    values: {
      positionUsdMicros: "100000000",
      maxEntryImpactBps: "200",
      maxRoundTripLossBps: "800",
      minimumExitDepthMultiple: "10",
      minimumOrganicBuyerCount: "10",
      maxTopTenHolderConcentrationBps: "4000",
    },
  },
  brokerConfig: { id: "solana-paper-broker-v2", values: { maxOpenPositions: "3" } },
  followedWallets: {
    version: "3",
    wallets: ["11111111111111111111111111111111"],
    labels: { "11111111111111111111111111111111": "Gasp (#1 monthly)" },
    maximumWallets: "100",
    updatedAt: "2026-08-01T12:00:00Z",
  },
  validation: null,
  discovery: [{
    wallet: "D1scWa11etAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1",
    runnerCount: 2,
    bestRank: 1,
    bestMultipleBps: "40000",
    alreadyFollowed: false,
    evidence: [],
  }],
  live: {
    mode: "paper",
    config: {
      id: "solana-live-v1",
      values: { perTradeCapUsdMicros: "250000000", dailyCapUsdMicros: "1000000000" },
    },
    dailySpendUsdMicros: "0",
    intents: [],
    positions: [],
    fills: [],
  },
};

describe("wallet flow", () => {
  it("shows what the stream last delivered and what it is watching", () => {
    const html = renderToStaticMarkup(
      <WalletFlow snap={{ walletFlow: FLOW } as unknown as Snapshot} strategy="solana_wallet_flow_quant" />,
    );
    expect(html).toContain("Stream");
    expect(html).toContain("Decision");
    expect(html).toContain("Capture");
    // Nothing has arrived on a first read, so the strip must not claim it has.
    expect(html).toContain("idle");
    expect(html).toContain("1 candidate");
  });

  it("shows the evidence behind each candidate and marks only the breached gate", () => {
    const html = renderToStaticMarkup(
      <WalletFlow snap={{ walletFlow: FLOW } as unknown as Snapshot} strategy="solana_wallet_flow_quant" />,
    );
    expect(html).toContain("Candidates examined");
    expect(html).toContain("1 scored");
    expect(html).toContain("top ten concentration");
    // The measurements the score was computed from, not just the verdict.
    expect(html).toContain("0.96%");
    expect(html).toContain("7.20%");
    expect(html).toContain("14.0×");
    expect(html).toContain("74.0%");
    // Concentration is the only gate this candidate breached.
    expect(html.match(/gate-bad/g)).toHaveLength(1);
  });

  it("names the wallet and reason behind a capture gap", () => {
    const gapped = {
      ...FLOW,
      cursors: [{ wallet: "CyaE1VxvBrahnPWkqm5VsdCvyS2QmNht2UFrKJHga54o", captureComplete: false, gapReason: "backfill_limit_reached" }],
    };
    const html = renderToStaticMarkup(
      <WalletFlow snap={{ walletFlow: gapped } as unknown as Snapshot} strategy="solana_wallet_flow_quant" />,
    );
    expect(html).toContain("CyaE1V…a54o");
    // The reason names what the operator has to decide, not the capture code.
    expect(html).toContain("a bot, not a copy-trade target");
  });

  it("reports gapped capture ahead of any arrival state", () => {
    const gapped = {
      ...FLOW,
      cursors: [{ wallet: "11111111111111111111111111111111", captureComplete: false, gapReason: "cursor_not_recovered" }],
    };
    const html = renderToStaticMarkup(
      <WalletFlow snap={{ walletFlow: gapped } as unknown as Snapshot} strategy="solana_wallet_flow_quant" />,
    );
    expect(html).toContain("1 wallet gapped");
  });

  it("renders the account, ladder state, and exit reasons", () => {
    const html = renderToStaticMarkup(
      <WalletFlow snap={{ walletFlow: FLOW } as unknown as Snapshot} strategy="solana_wallet_flow_quant" />,
    );
    expect(html).toContain("riding house money");
    expect(html).toContain("migrated");
    expect(html).toContain("time stop flat");
    expect(html).toContain("1/3 slots");
    expect(html).toContain("+98.98");
    expect(html).toContain("recoup");
  });

  it("nominates discovered wallets with an audited follow action", () => {
    const html = renderToStaticMarkup(
      <WalletFlow snap={{ walletFlow: FLOW } as unknown as Snapshot} strategy="solana_wallet_flow_quant" />,
    );
    expect(html).toContain("Wallet discovery");
    expect(html).toContain("D1scWa…AAA1");
    expect(html).toContain("4.0×");
    expect(html).toContain("Follow");
  });

  it("keeps live trading behind a two-step arm and shows the caps", () => {
    const html = renderToStaticMarkup(
      <WalletFlow snap={{ walletFlow: FLOW } as unknown as Snapshot} strategy="solana_wallet_flow_quant" />,
    );
    expect(html).toContain("Arm live trading…");
    expect(html).not.toContain("Confirm: trade real funds");
    expect(html).toContain("250/trade");
    expect(html).toContain("1,000/day");
  });

  it("shows the disarm switch while live", () => {
    const html = renderToStaticMarkup(
      <LiveControl mode="live" strategy="solana_wallet_flow_quant" />,
    );
    expect(html).toContain("LIVE — real funds at risk");
    expect(html).toContain("Disarm live trading");
  });

  it("adds and removes followed Solana wallets on the fly, under their names", () => {
    const wallet = "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";
    const html = renderToStaticMarkup(
      <SolanaWalletConfig config={{
        version: "3",
        wallets: [wallet],
        labels: { [wallet]: "Pain (#2 monthly)" },
        maximumWallets: "100",
        updatedAt: "2026-08-01T12:00:00Z",
      }} />,
    );
    expect(html).toContain("Follow wallet");
    expect(html).toContain(wallet);
    expect(html).toContain("Pain (#2 monthly)");
    expect(html).toContain("Remove");
    expect(html).toContain("1/100 followed");
  });

  it("groups candidates under the trader whose buy triggered them", () => {
    const html = renderToStaticMarkup(
      <WalletFlow snap={{ walletFlow: FLOW } as unknown as Snapshot} strategy="solana_wallet_flow_quant" />,
    );
    // The cohort name, not the base58 key, is how a trader is identified.
    expect(html).toContain("group-row");
    expect(html.match(/Gasp \(#1 monthly\)/g)?.length).toBeGreaterThanOrEqual(2);
  });
});
