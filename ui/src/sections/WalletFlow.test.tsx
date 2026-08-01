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
  strategyConfig: { id: "solana-wallet-flow-v2", values: { positionUsdMicros: "100000000" } },
  brokerConfig: { id: "solana-paper-broker-v2", values: { maxOpenPositions: "3" } },
  followedWallets: {
    version: "3",
    wallets: ["11111111111111111111111111111111"],
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
});
