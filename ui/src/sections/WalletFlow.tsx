import { useState, type FormEvent } from "react";
import {
  configureSolanaWallets,
  control,
  type Snapshot,
  type WalletCohort,
  type WalletFlow as WalletFlowState,
  type WalletFlowPosition,
} from "../api";
import { age, fmt, micros, ms, pct } from "../fmt";
import {
  Chip, Empty, Panel, Section, Since, Spin, Stat, useArrivals, useNow, type Tone,
} from "../ui";

const shortMint = (mint: string) => `${mint.slice(0, 4)}…${mint.slice(-4)}`;
const shortWallet = (wallet: string) => `${wallet.slice(0, 6)}…${wallet.slice(-4)}`;
const SOLANA_WALLET = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

// A gap reason is a capture verdict, and two of them say something about the
// wallet rather than the connection: an address transacting faster than the
// signature pages can be walked is a bot, not a trader worth following.
const GAP_HELP: Record<string, string> = {
  backfill_limit_reached: "transacts faster than capture can page it — a bot, not a copy-trade target",
  cursor_not_recovered: "the provider no longer serves the last signature seen",
};

const EXIT_TONE: Record<string, Tone> = {
  RECOUP: "ok",
  TRAILING_STOP: "ok",
  STOP_LOSS: "warn",
  TIME_STOP_FLAT: "mute",
  TIME_STOP_MAX: "mute",
  ORGANIC_FLOW_COLLAPSE: "warn",
  EXIT_NO_LIQUIDITY: "crit",
};

function returnBps(position: WalletFlowPosition): number | null {
  if (position.realizedPnlUsdMicros === null) return null;
  const cost = Number(position.entryCostUsdMicros);
  if (!cost) return null;
  return (Number(position.realizedPnlUsdMicros) * 10000) / cost;
}

export function SolanaWalletConfig({ config }: { config: WalletCohort }) {
  const [wallets, setWallets] = useState(config.wallets);
  const [value, setValue] = useState("");
  const [status, setStatus] = useState("");
  const [saving, setSaving] = useState(false);
  const maximum = Number(config.maximumWallets) || 100;

  const update = async (next: string[], success: string) => {
    setSaving(true);
    setStatus("");
    try {
      await configureSolanaWallets(next);
      setWallets(next);
      setStatus(success);
      return true;
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Solana wallet update failed.");
      return false;
    } finally {
      setSaving(false);
    }
  };

  const add = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const wallet = value.trim();
    if (!SOLANA_WALLET.test(wallet)) {
      setStatus("Enter a valid base58 Solana public key.");
      return;
    }
    if (wallets.includes(wallet)) {
      setStatus("That wallet is already followed.");
      return;
    }
    if (wallets.length >= maximum) {
      setStatus(`At most ${maximum} wallets can be followed.`);
      return;
    }
    if (await update([...wallets, wallet], `Now following ${shortWallet(wallet)}.`)) setValue("");
  };

  return (
    <div className="wallet-config solana-wallet-config">
      <form className="solana-wallet-add" onSubmit={add}>
        <label htmlFor="solana-wallet">Solana public key</label>
        <input
          id="solana-wallet"
          aria-describedby="solana-wallet-help"
          autoComplete="off"
          disabled={saving || wallets.length >= maximum}
          spellCheck={false}
          value={value}
          onChange={(event) => setValue(event.target.value)}
          placeholder="Base58 public key"
        />
        <button type="submit" disabled={saving || wallets.length >= maximum}>
          {saving && <Spin on />}
          Follow wallet
        </button>
        <span id="solana-wallet-help">
          Changes are durable and reach the observer on its next poll.
        </span>
      </form>
      {wallets.length > 0 ? (
        <ul className="solana-wallet-list" aria-label="Followed Solana wallets">
          {wallets.map((wallet) => (
            <li key={wallet}>
              <code>{wallet}</code>
              <button
                type="button"
                aria-label={`Remove ${wallet}`}
                disabled={saving}
                onClick={() => void update(
                  wallets.filter((candidate) => candidate !== wallet),
                  `Stopped following ${shortWallet(wallet)}.`,
                )}
              >
                Remove
              </button>
            </li>
          ))}
        </ul>
      ) : (
        <span className="solana-wallet-empty">No Solana wallets followed.</span>
      )}
      <span className="solana-wallet-status" role="status" aria-live="polite">
        {saving ? "Updating the live cohort…" : status || `${wallets.length}/${maximum} followed`}
      </span>
    </div>
  );
}

/**
 * The live switch. Two-step arm with the risk stated on the button itself;
 * the proxy generates the approval literal, so this button is the whole
 * browser-side surface. Disarm is immediate.
 */
export function LiveControl({ mode, strategy }: { mode: "paper" | "live"; strategy: string }) {
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const flip = async (action: "arm-live" | "disarm-live") => {
    setBusy(true);
    setError("");
    try {
      await control(action, strategy);
      setConfirming(false);
    } catch (raised) {
      setError(raised instanceof Error ? raised.message : "mode change failed");
    } finally {
      setBusy(false);
    }
  };

  if (mode === "live") {
    return (
      <div className="live-control">
        <Chip tone="crit">LIVE — real funds at risk</Chip>
        <button type="button" disabled={busy} onClick={() => void flip("disarm-live")}>
          {busy && <Spin on />}
          Disarm live trading
        </button>
        {error && <span role="alert">{error}</span>}
      </div>
    );
  }
  return (
    <div className="live-control">
      <Chip tone="mute">paper</Chip>
      {confirming ? (
        <>
          <button
            type="button"
            className="danger"
            disabled={busy}
            onClick={() => void flip("arm-live")}
          >
            {busy && <Spin on />}
            Confirm: trade real funds
          </button>
          <button type="button" disabled={busy} onClick={() => setConfirming(false)}>
            Cancel
          </button>
        </>
      ) : (
        <button type="button" onClick={() => setConfirming(true)}>
          Arm live trading…
        </button>
      )}
      {error && <span role="alert">{error}</span>}
    </div>
  );
}

const newest = (values: (string | null | undefined)[]): number =>
  values.reduce<number>((latest, value) => Math.max(latest, ms(value)), 0);

/**
 * Acquisitions arrive over a socket, so the operator needs to see the stream
 * itself: what landed, how long ago, and whether capture is still complete.
 * Every field here is derived from the read model the console already polls.
 */
function Stream({ flow }: { flow: WalletFlowState }) {
  const now = useNow();
  const arrivals = useArrivals(flow.actions, (action) => action.id);
  const lastDecisionMs = newest(flow.actions.map((action) => action.processedAtMs));
  const lastSnapshotMs = newest(
    flow.openMints.map((mint) => (mint as { snapshotObservedAtMs?: string }).snapshotObservedAtMs),
  );
  const lastCaptureMs = newest(flow.cursors.map((cursor) => (cursor as { observedAtMs?: string }).observedAtMs));
  const gapped = flow.cursors.filter((cursor) => !cursor.captureComplete).length;
  const receivedMs = Math.max(arrivals.lastAtMs, 0);
  const receiving = receivedMs > 0 && now - receivedMs < 30_000;
  const recentDecisions = flow.actions.filter(
    (action) => now - ms(action.processedAtMs) < 300_000,
  ).length;

  return (
    <Panel
      label="Stream"
      hint="Followed-wallet acquisitions arrive over a subscription; the sweep and the exit monitor keep their own clocks. These are the last things this console saw land."
      aside={
        <Chip tone={gapped > 0 ? "crit" : receiving ? "ok" : "mute"}>
          {gapped > 0
            ? `${gapped} wallet${gapped === 1 ? "" : "s"} gapped`
            : receiving ? "receiving" : "idle"}
        </Chip>
      }
    >
      <div className="stream">
        <div className={arrivals.fresh.size > 0 ? "stream-item arrived" : "stream-item"}>
          <span className="lbl">Decision</span>
          <Since at={lastDecisionMs} verb="" freshMs={60_000} />
        </div>
        <div className="stream-item">
          <span className="lbl">Snapshot</span>
          <Since at={lastSnapshotMs} verb="" freshMs={60_000} />
        </div>
        <div className="stream-item">
          <span className="lbl">Capture</span>
          <Since at={lastCaptureMs} verb="" freshMs={120_000} />
        </div>
        <div className="stream-item">
          <span className="lbl">Last 5 min</span>
          <span className="stream-count">
            {recentDecisions} decision{recentDecisions === 1 ? "" : "s"}
          </span>
        </div>
        <div className="stream-item">
          <span className="lbl">Watching</span>
          <span className="stream-count">
            {flow.openMints.length} candidate{flow.openMints.length === 1 ? "" : "s"}
          </span>
        </div>
      </div>
    </Panel>
  );
}

function Positions({ flow }: { flow: WalletFlowState }) {
  const arrivals = useArrivals(flow.positions, (position) => `${position.id}:${position.status}`);
  const open = flow.positions.filter((p) => p.status === "open");
  const closed = flow.positions.filter((p) => p.status === "closed").slice(0, 12);
  const maxSlots = Number(flow.brokerConfig?.values.maxOpenPositions ?? 0) || 0;

  return (
    <Panel
      label="Positions"
      hint="Open positions recoup their cost at the ladder and ride the remainder under a trailing stop. Risk exits fire immediately; flow and liquidity exits need consecutive confirming snapshots."
      aside={<span className="micro">{open.length}/{maxSlots || "—"} slots</span>}
    >
      {flow.positions.length === 0 ? (
        <Empty msg="No paper positions yet. Entries need a followed wallet's acquisition to clear every gate." />
      ) : (
        <div className="tw">
          <table>
            <thead>
              <tr>
                <th scope="col">Mint</th>
                <th scope="col">State</th>
                <th scope="col" className="n">Age</th>
                <th scope="col" className="n">Entry cost</th>
                <th scope="col" className="n">Remaining</th>
                <th scope="col" className="n">Peak</th>
                <th scope="col">Exit</th>
                <th scope="col" className="n">Realized</th>
              </tr>
            </thead>
            <tbody>
              {[...open, ...closed].map((position) => {
                const realized = returnBps(position);
                const remainingPct = Number(position.quantityAtoms)
                  ? (Number(position.remainingQuantityAtoms) * 100) / Number(position.quantityAtoms)
                  : 0;
                return (
                  <tr
                    key={position.id}
                    className={arrivals.fresh.has(`${position.id}:${position.status}`) ? "arrived" : undefined}
                  >
                    <td><code>{shortMint(position.mint)}</code></td>
                    <td>
                      <Chip tone={position.status === "open" ? (position.recouped ? "ok" : "warn") : "mute"}>
                        {position.status === "open"
                          ? position.recouped ? "riding house money" : "at risk"
                          : "closed"}
                      </Chip>
                      {position.migrationCrossed && <Chip tone="ok">migrated</Chip>}
                    </td>
                    <td className="n">
                      {age(Number(position.closedAtMs ?? Date.now()) - Number(position.openedAtMs))}
                    </td>
                    <td className="n">{fmt(micros(position.entryCostUsdMicros), 2)}</td>
                    <td className="n">{position.status === "open" ? `${remainingPct.toFixed(0)}%` : "—"}</td>
                    <td className="n">{pct(String((Number(position.peakReturnBps) - 10000) * 100), 1)}</td>
                    <td>
                      {position.exitReason
                        ? <Chip tone={EXIT_TONE[position.exitReason] ?? "warn"}>{position.exitReason.toLowerCase().replaceAll("_", " ")}</Chip>
                        : position.exitLegs.length > 0
                          ? <Chip tone="ok">recouped leg {position.exitLegs.length}</Chip>
                          : "—"}
                    </td>
                    <td className="n">
                      {position.realizedPnlUsdMicros === null
                        ? "—"
                        : `${fmt(micros(position.realizedPnlUsdMicros), 2, { signed: true })}${realized === null ? "" : ` (${(realized / 100).toFixed(1)}%)`}`}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </Panel>
  );
}

const DECISION_TONE: Record<string, Tone> = { ENTER: "ok", WATCH: "warn", REJECT: "mute" };

/** A gate reading, coloured only when it is the reason a candidate failed. */
const Gate = ({ text, failed }: { text: string; failed: boolean }) =>
  failed ? <strong className="gate-bad">{text}</strong> : <>{text}</>;

const tokens = (atoms: string, decimals: number): string =>
  (Number(atoms) / 10 ** decimals).toLocaleString(undefined, { maximumFractionDigits: 2 });

function Candidates({ flow }: { flow: WalletFlowState }) {
  const [open, setOpen] = useState<string | null>(null);
  const arrivals = useArrivals(flow.candidates, (candidate) => candidate.snapshotEventId);
  const gates = flow.strategyConfig?.values ?? {};
  const limit = (name: string) => Number(gates[name] ?? 0);
  const positionUsd = Number(gates.positionUsdMicros ?? 0);
  const maxImpact = limit("maxEntryImpactBps");
  const maxRoundTrip = limit("maxRoundTripLossBps");
  const minDepth = limit("minimumExitDepthMultiple");
  const minBuyers = limit("minimumOrganicBuyerCount");
  const maxConcentration = limit("maxTopTenHolderConcentrationBps");

  return (
    <Panel
      label="Candidates examined"
      hint="Every mint a followed wallet bought, with the evidence it was scored on. A value is red when it breaches its frozen gate. Select a row for the full snapshot."
      aside={<span className="micro">{flow.candidates.length} scored</span>}
    >
      {flow.candidates.length === 0 ? (
        <Empty msg="No candidates scored yet. Each one needs a followed wallet to buy a mint." />
      ) : (
        <div className="tw">
          <table>
            <thead>
              <tr>
                <th scope="col">Mint</th>
                <th scope="col">Decision</th>
                <th scope="col">Reason</th>
                <th scope="col" className="n">Score</th>
                <th scope="col" className="n">Cap</th>
                <th scope="col" className="n">Impact</th>
                <th scope="col" className="n">Round trip</th>
                <th scope="col" className="n">Exit depth</th>
                <th scope="col" className="n">Buyers</th>
                <th scope="col" className="n">Top 10</th>
                <th scope="col" className="n">When</th>
              </tr>
            </thead>
            <tbody>
              {flow.candidates.map((candidate) => {
                const depthMultiple = positionUsd
                  ? Number(candidate.exitDepthUsdMicros) / positionUsd
                  : 0;
                const expanded = open === candidate.snapshotEventId;
                return [
                  <tr
                    key={candidate.snapshotEventId}
                    onClick={() => setOpen(expanded ? null : candidate.snapshotEventId)}
                    className={arrivals.fresh.has(candidate.snapshotEventId) ? "arrived row-pick" : "row-pick"}
                  >
                    <td><code title={candidate.mint}>{shortMint(candidate.mint)}</code></td>
                    <td>
                      <Chip tone={DECISION_TONE[candidate.decision] ?? "mute"}>
                        {candidate.decision.toLowerCase()}
                      </Chip>
                    </td>
                    <td>{candidate.reason.toLowerCase().replaceAll("_", " ")}</td>
                    <td className="n">{(candidate.totalScoreBps / 100).toFixed(0)}</td>
                    <td className="n">{fmt(micros(candidate.marketCapUsdMicros), 0) ?? "—"}</td>
                    <td className="n">
                      <Gate
                        text={`${(candidate.entryPriceImpactBps / 100).toFixed(2)}%`}
                        failed={maxImpact > 0 && candidate.entryPriceImpactBps > maxImpact}
                      />
                    </td>
                    <td className="n">
                      <Gate
                        text={`${(candidate.roundTripLossBps / 100).toFixed(2)}%`}
                        failed={maxRoundTrip > 0 && candidate.roundTripLossBps > maxRoundTrip}
                      />
                    </td>
                    <td className="n">
                      <Gate
                        text={`${depthMultiple.toFixed(1)}×`}
                        failed={minDepth > 0 && depthMultiple < minDepth}
                      />
                    </td>
                    <td className="n">
                      <Gate
                        text={String(candidate.unlinkedBuyerCount)}
                        failed={minBuyers > 0 && candidate.unlinkedBuyerCount < minBuyers}
                      />
                    </td>
                    <td className="n">
                      <Gate
                        text={`${(candidate.topTenHolderConcentrationBps / 100).toFixed(1)}%`}
                        failed={
                          maxConcentration > 0
                          && candidate.topTenHolderConcentrationBps > maxConcentration
                        }
                      />
                    </td>
                    <td className="n"><Since at={ms(candidate.observedAtMs)} verb="" /></td>
                  </tr>,
                  expanded && (
                    <tr key={`${candidate.snapshotEventId}:detail`}>
                      <td colSpan={11}>
                        <dl className="facts">
                          <dt>Mint</dt><dd><code>{candidate.mint}</code></dd>
                          <dt>Bought by</dt><dd><code>{candidate.wallet}</code></dd>
                          <dt>Token program</dt>
                          <dd>
                            {candidate.tokenProgram} · {candidate.decimals} decimals ·{" "}
                            {tokens(candidate.supplyAtoms, candidate.decimals)} supply
                          </dd>
                          <dt>Quoted entry</dt>
                          <dd>
                            {fmt(micros(candidate.buyInputUsdMicros), 2)} USD buys{" "}
                            {tokens(candidate.buyOutputAtoms, candidate.decimals)} tokens; selling
                            them back returns {fmt(micros(candidate.sellOutputUsdMicros), 2)} USD
                          </dd>
                          <dt>Exit depth</dt>
                          <dd>
                            {fmt(micros(candidate.exitDepthUsdMicros), 2)} USD exits within the
                            impact bound
                          </dd>
                          <dt>Organic flow</dt>
                          <dd>
                            {candidate.unlinkedBuyerCount} unlinked buyers ·{" "}
                            {fmt(micros(candidate.netQuoteInflowUsdMicros), 2, { signed: true })} net
                            inflow · {fmt(micros(candidate.volumeUsdMicros5m), 2)} volume over 5m
                          </dd>
                          <dt>Insider inventory</dt>
                          <dd>
                            creator holds {tokens(candidate.creatorInventoryAtoms, candidate.decimals)}
                            {candidate.creatorSold ? " and has sold" : " and has not sold"}; cluster
                            holds {tokens(candidate.clusterInventoryAtoms, candidate.decimals)}
                            {candidate.clusterSold ? " and has sold" : " and has not sold"}
                          </dd>
                          <dt>Authorities</dt>
                          <dd>
                            mint {candidate.mintAuthorityDisabled ? "disabled" : "LIVE"} · freeze{" "}
                            {candidate.freezeAuthorityDisabled ? "disabled" : "LIVE"}
                          </dd>
                          <dt>Venue</dt>
                          <dd>
                            {candidate.migrationStatus.toLowerCase().replaceAll("_", " ")} ·{" "}
                            {candidate.routeLabels.join(", ") || "—"}
                          </dd>
                          <dt>Score</dt>
                          <dd>
                            wallet {(candidate.walletScoreBps / 100).toFixed(0)} · token{" "}
                            {(candidate.tokenScoreBps / 100).toFixed(0)} · liquidity{" "}
                            {(candidate.liquidityScoreBps / 100).toFixed(0)} · flow{" "}
                            {(candidate.flowScoreBps / 100).toFixed(0)} → total{" "}
                            {(candidate.totalScoreBps / 100).toFixed(0)}
                          </dd>
                          <dt>Snapshot</dt><dd><code>{candidate.snapshotEventId}</code></dd>
                        </dl>
                      </td>
                    </tr>
                  ),
                ];
              })}
            </tbody>
          </table>
        </div>
      )}
    </Panel>
  );
}

function Discovery({ flow }: { flow: WalletFlowState }) {
  const cohort = flow.followedWallets?.wallets ?? [];
  const [busy, setBusy] = useState("");
  const [status, setStatus] = useState("");

  const follow = async (wallet: string) => {
    setBusy(wallet);
    setStatus("");
    try {
      await configureSolanaWallets([...cohort, wallet]);
      setStatus(`Now following ${shortWallet(wallet)}.`);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Follow failed.");
    } finally {
      setBusy("");
    }
  };

  return (
    <Panel
      label="Wallet discovery"
      hint="Wallets that were repeatedly early into mints that later ran. Nominations are evidence only — following one is the same audited cohort change as adding it by hand."
    >
      {flow.discovery.length === 0 ? (
        <Empty msg="No nominations yet. Discovery needs captured candidates whose price later ran." />
      ) : (
        <>
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th scope="col">Wallet</th>
                  <th scope="col" className="n">Runners</th>
                  <th scope="col" className="n">Best rank</th>
                  <th scope="col" className="n">Best multiple</th>
                  <th scope="col">State</th>
                </tr>
              </thead>
              <tbody>
                {flow.discovery.map((candidate) => (
                  <tr key={candidate.wallet}>
                    <td><code>{shortWallet(candidate.wallet)}</code></td>
                    <td className="n">{candidate.runnerCount}</td>
                    <td className="n">#{candidate.bestRank}</td>
                    <td className="n">{(Number(candidate.bestMultipleBps) / 10000).toFixed(1)}×</td>
                    <td>
                      {candidate.alreadyFollowed ? (
                        <Chip tone="ok">followed</Chip>
                      ) : (
                        <button
                          type="button"
                          disabled={busy !== ""}
                          onClick={() => void follow(candidate.wallet)}
                        >
                          {busy === candidate.wallet && <Spin on />}
                          Follow
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {status && <span role="status" className="discovery-status">{status}</span>}
        </>
      )}
    </Panel>
  );
}

function Live({ flow, strategy }: { flow: WalletFlowState; strategy: string }) {
  const live = flow.live;
  if (!live) return null;
  const caps = live.config?.values;

  return (
    <Panel
      label="Live execution"
      hint="Default off. Arming mirrors every filled paper action into a capped live intent; a separate executor process holding the only signing key must also be running. Stopping the strategy disarms automatically."
      aside={<span className="micro">
        {caps
          ? `caps ${fmt(micros(caps.perTradeCapUsdMicros ?? "0"), 0)}/trade · ${fmt(micros(caps.dailyCapUsdMicros ?? "0"), 0)}/day`
          : ""}
      </span>}
    >
      <LiveControl mode={live.mode} strategy={strategy} />
      {live.mode === "live" && (
        <p className="live-note">
          Daily spend {fmt(micros(live.dailySpendUsdMicros), 2)} USD.
          Intents expire unexecuted unless the solana-live executor profile is
          running with a signer key.
        </p>
      )}
      {live.intents.length > 0 && (
        <div className="tw">
          <table>
            <thead>
              <tr>
                <th scope="col">Intent</th>
                <th scope="col">Mint</th>
                <th scope="col">Reason</th>
                <th scope="col" className="n">Size</th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              {live.intents.slice(0, 12).map((intent) => (
                <tr key={intent.id}>
                  <td>{intent.kind}</td>
                  <td><code>{shortMint(intent.mint)}</code></td>
                  <td>{intent.reason.toLowerCase().replaceAll("_", " ")}</td>
                  <td className="n">
                    {intent.kind === "ENTRY"
                      ? fmt(micros(intent.inputUsdMicros), 2)
                      : `${(intent.fractionBps / 100).toFixed(0)}%`}
                  </td>
                  <td>
                    <Chip tone={
                      intent.status === "filled" ? "ok"
                        : intent.status === "failed" || intent.status === "expired" ? "crit"
                          : "mute"
                    }>
                      {intent.status}
                    </Chip>
                    {intent.failureReason && <span className="micro"> {intent.failureReason}</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {live.positions.length > 0 && (
        <div className="tw">
          <table>
            <thead>
              <tr>
                <th scope="col">Live position</th>
                <th scope="col">State</th>
                <th scope="col" className="n">Cost</th>
                <th scope="col" className="n">Proceeds</th>
                <th scope="col" className="n">Fees (lamports)</th>
              </tr>
            </thead>
            <tbody>
              {live.positions.map((position) => (
                <tr key={position.mint + position.openedAtMs}>
                  <td><code>{shortMint(position.mint)}</code></td>
                  <td><Chip tone={position.status === "open" ? "warn" : "mute"}>{position.status}</Chip></td>
                  <td className="n">{fmt(micros(position.costUsdMicros), 2)}</td>
                  <td className="n">{fmt(micros(position.proceedsUsdMicros), 2)}</td>
                  <td className="n">{position.feeLamports}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Panel>
  );
}

/**
 * The wallet-flow strategy's own page: account, live switch, positions,
 * discovery, cohort, and the recent broker decisions. Everything else in the
 * console is registry-generic; this strategy has the richest data, so it gets
 * the one bespoke view.
 */
export function WalletFlow({ snap, strategy }: { snap: Snapshot; strategy: string }) {
  const flow = snap.walletFlow;
  if (!flow) {
    return (
      <Section title="Wallet flow">
        <Empty msg="The collector has not served the wallet-flow state yet." />
      </Section>
    );
  }
  const account = flow.paperAccount;
  const gaps = flow.cursors.filter((cursor) => !cursor.captureComplete);
  const cohort = flow.followedWallets ?? {
    version: "0", wallets: [], maximumWallets: "100", updatedAt: "",
  };

  return (
    <Section
      title="Wallet flow"
      note="Follow configured wallets' confirmed acquisitions, survival-score each exact mint, and trade the survivors: recoup cost at the ladder, ride the remainder behind a trailing stop."
    >
      {account && (
        <div className="stats rise">
          <Stat
            label="Paper cash"
            value={fmt(micros(account.cashBalanceUsdMicros), 2) ?? "—"}
            cap="USD"
          />
          <Stat
            label="Realized P&L"
            value={fmt(micros(account.realizedPnlUsdMicros), 2, { signed: true }) ?? "—"}
            cap="USD"
            tone={Number(account.realizedPnlUsdMicros) > 0 ? "ok"
              : Number(account.realizedPnlUsdMicros) < 0 ? "crit" : undefined}
          />
          <Stat
            label="Position size"
            value={fmt(micros(flow.strategyConfig?.values.positionUsdMicros ?? "0"), 0) ?? "—"}
            cap="USD per entry"
          />
          <Stat
            label="Capture"
            value={gaps.length === 0 ? "complete" : `${gaps.length} gapped`}
            cap={gaps.length === 0
              ? "every followed wallet is fully captured"
              : gaps
                .map((gap) => `${shortWallet(gap.wallet)} ${
                  GAP_HELP[gap.gapReason ?? ""] ?? (gap.gapReason ?? "gapped").replaceAll("_", " ")
                }`)
                .join(" · ")}
            tone={gaps.length === 0 ? "ok" : "crit"}
          />
        </div>
      )}

      <Stream flow={flow} />
      <Live flow={flow} strategy={strategy} />
      <Positions flow={flow} />
      <Candidates flow={flow} />
      <Discovery flow={flow} />

      <Panel
        label="Followed wallets"
        hint="The cohort is the strategy's actual edge. Replacing it is atomic, audited, and needs no restart."
        aside={<Since at={ms(cohort.updatedAt)} verb="configured" />}
      >
        <SolanaWalletConfig key={cohort.version} config={cohort} />
      </Panel>

      <Decisions flow={flow} />
    </Section>
  );
}

function Decisions({ flow }: { flow: WalletFlowState }) {
  const arrivals = useArrivals(flow.actions, (action) => action.id);
  return (
      <Panel
        label="Recent decisions"
        hint="Every snapshot produces exactly one action, including the holds and skips — the evidence trail is complete by construction."
      >
        {flow.actions.length === 0 ? (
          <Empty msg="No broker actions yet." />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th scope="col">Action</th>
                  <th scope="col">Status</th>
                  <th scope="col">Reason</th>
                  <th scope="col" className="n">Cash delta</th>
                  <th scope="col" className="n">When</th>
                </tr>
              </thead>
              <tbody>
                {flow.actions.slice(0, 15).map((action) => (
                  <tr key={action.id} className={arrivals.fresh.has(action.id) ? "arrived" : undefined}>
                    <td>{action.action}</td>
                    <td>
                      <Chip tone={action.status === "FILLED" ? "ok" : action.status === "REJECTED" ? "mute" : "warn"}>
                        {action.status.toLowerCase()}
                      </Chip>
                    </td>
                    <td>{action.reason.toLowerCase().replaceAll("_", " ")}</td>
                    <td className="n">{fmt(micros(action.cashDeltaUsdMicros), 2, { signed: true })}</td>
                    <td className="n"><Since at={ms(action.processedAtMs)} verb="" /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Panel>
  );
}
