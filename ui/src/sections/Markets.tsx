import { useState, type FormEvent } from "react";
import {
  configureSolanaWallets,
  configureWallets,
  type Snapshot,
  type WalletCohort,
  type WalletTracking,
} from "../api";
import { fmt, micros, ms, pct } from "../fmt";
import { Chip, Empty, Panel, Section, Since, Spin } from "../ui";

const signedPpm = (value: string) => `${Number(value) >= 0 ? "+" : ""}${value}`;
const shortWallet = (wallet: string) => `${wallet.slice(0, 6)}…${wallet.slice(-4)}`;
const WALLET = /^0x[0-9a-f]{40}$/;
const SOLANA_WALLET = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

/** Each scan's own clock, beside its gate. A stale table and a quiet market
 *  look identical without it. */
const ScanAside = ({ at, gate }: { at: string | undefined; gate?: string }) => (
  <span className="scan-aside">
    {gate && <span className="micro">{gate}</span>}
    <Since at={ms(at)} verb="scanned" />
  </span>
);

/** Every scan table ends in the same three-state verdict, so it renders once. */
const State = ({ eligible, ready, depth = true }: { eligible: boolean; ready: boolean; depth?: boolean }) => (
  <Chip tone={eligible ? "ok" : ready ? "warn" : "mute"}>
    {eligible ? "clears gate" : !depth ? "no executable route" : ready ? "below gate" : "warming up"}
  </Chip>
);

export function WalletConfig({ config }: { config: WalletTracking["config"] }) {
  const [value, setValue] = useState(config.wallets.join("\n"));
  const [status, setStatus] = useState("");
  const [saving, setSaving] = useState(false);
  const maximum = Number(config.maximumWallets) || 50;

  const save = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const wallets = value.split(/[\s,]+/).filter(Boolean).map((wallet) => wallet.toLowerCase());
    if (wallets.length > maximum) {
      setStatus(`Enter at most ${maximum} wallets.`);
      return;
    }
    if (new Set(wallets).size !== wallets.length) {
      setStatus("Remove duplicate wallets.");
      return;
    }
    if (wallets.some((wallet) => !WALLET.test(wallet))) {
      setStatus("Each wallet must be a 0x address with 40 hexadecimal characters.");
      return;
    }
    setSaving(true);
    setStatus("");
    try {
      await configureWallets(wallets);
      setValue(wallets.join("\n"));
      setStatus(`Saved ${wallets.length} wallet${wallets.length === 1 ? "" : "s"}.`);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Wallet update failed.");
    } finally {
      setSaving(false);
    }
  };

  return (
    <form className="wallet-config" onSubmit={save}>
      <div>
        <label htmlFor="hyperliquid-wallets">Hyperliquid wallets</label>
        <span id="wallet-help">
          One address per line. Saving replaces the live cohort; no restart is needed.
        </span>
      </div>
      <textarea
        id="hyperliquid-wallets"
        aria-describedby="wallet-help"
        rows={Math.max(3, Math.min(8, config.wallets.length + 1))}
        spellCheck={false}
        value={value}
        onChange={(event) => setValue(event.target.value)}
        placeholder="0x…"
      />
      <div className="wallet-config-actions">
        <span role="status">
          {saving ? "Sending the cohort to the collector…" : status || `${config.wallets.length}/${maximum} configured`}
        </span>
        <button type="submit" disabled={saving} aria-busy={saving}>
          {saving && <Spin on />}
          {saving ? "Saving…" : "Save cohort"}
        </button>
      </div>
    </form>
  );
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
 * What the collector can see, before any strategy acts on it. Split out of the
 * overview: these are four dense research tables and they were burying the
 * nine strategy cards above them.
 */
export function Markets({ snap }: { snap: Snapshot }) {
  const funding = snap.fundingLeaderboard;
  const items = funding?.items ?? [];
  const reverse = snap.reverseCarryLeaderboard;
  const reverseItems = reverse?.items ?? [];
  const crossVenue = snap.crossVenueLeaderboard;
  const crossVenueItems = crossVenue?.items ?? [];
  const wallet = snap.walletTracking;
  const walletScores = wallet?.scores.items ?? [];
  const walletConfig = wallet?.config ?? {
    version: "0",
    wallets: [],
    maximumWallets: "50",
    updatedAt: "",
  };
  const solanaWalletConfig = snap.solanaWalletConfig ?? {
    version: "0",
    wallets: [],
    maximumWallets: "100",
    updatedAt: "",
  };

  return (
    <Section
      title="Market scans"
      note="Continuous scans across venues. A market has to clear its gate here before any strategy will open a position — rates are in parts per million per hour (ppm/h)."
    >
      <Panel
        label="Solana wallet flow"
        hint="Confirmed acquisitions from followed wallets feed paper-only candidate monitoring. Add or remove wallets without restarting the observer."
        aside={<Since at={ms(solanaWalletConfig.updatedAt)} verb="configured" />}
      >
        <SolanaWalletConfig key={solanaWalletConfig.version} config={solanaWalletConfig} />
      </Panel>

      <Panel
        label="Wallet consistency"
        hint="Tracked Hyperliquid wallets scored on realised profit after fees and drawdown. Each mode needs 60 days of paper evidence before it could ever go live."
        aside={wallet && (
          <ScanAside
            at={wallet.scores.asOfMs}
            gate={`mirror ${wallet.assessment.modes.mirror.evidenceDays}/${wallet.assessment.modes.mirror.minimumDays} days`}
          />
        )}
      >
        <WalletConfig key={walletConfig.version} config={walletConfig} />
        {walletScores.length === 0 ? (
          <Empty msg="Add wallets above to start collecting the 60-day paper evidence." />
        ) : (
          <>
            <div className="tw">
              <table>
                <thead>
                  <tr>
                    <th scope="col">#</th>
                    <th scope="col">Wallet</th>
                    <th scope="col" className="n">Closed trades</th>
                    <th scope="col" className="n">Net USD</th>
                    <th scope="col" className="n">Max drawdown USD</th>
                    <th scope="col" className="n">Score</th>
                    <th scope="col">State</th>
                  </tr>
                </thead>
                <tbody>
                  {walletScores.map((score) => (
                    <tr key={score.wallet}>
                      <td>{score.rank}</td>
                      <td><strong>{shortWallet(score.wallet)}</strong></td>
                      <td className="n">{score.closedDecisions}</td>
                      <td className="n">{fmt(micros(score.netRealizedUsdMicros), 2, { signed: true })}</td>
                      <td className="n">{fmt(micros(score.maxDrawdownUsdMicros), 2)}</td>
                      <td className="n">{pct(score.scorePpm)}</td>
                      <td>
                        <Chip tone={score.qualified ? "ok" : "mute"}>
                          {score.qualified ? "qualified" : "warming up"}
                        </Chip>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="card-row pad">
              {(["flow", "mirror", "fade"] as const).map((mode) => {
                const gate = wallet!.assessment.modes[mode];
                return (
                  <Chip key={mode} tone={gate.verdict === "go" ? "ok" : gate.verdict === "kill" ? "warn" : "mute"}>
                    {mode} {gate.verdict} · {gate.evidenceDays}/{gate.minimumDays} days · {gate.closedDecisions}/{gate.minimumDecisions} trades
                  </Chip>
                );
              })}
              {wallet!.signals.map((signal) => (
                <Chip key={signal.asset} tone={signal.qualified ? "ok" : "mute"}>
                  {signal.asset} flow {signedPpm(signal.signalPpm)} ppm
                </Chip>
              ))}
            </div>
          </>
        )}
      </Panel>

      <Panel
        label="Funding rates"
        hint="Funding paid to shorts. The carry strategies enter when a market beats the gate and stays there."
        aside={funding && <ScanAside at={funding.asOfMs} gate={`gate ${signedPpm(funding.gateThresholdPpm)} ppm/h`} />}
      >
        {items.length === 0 ? (
          <Empty msg="Waiting for the first complete cross-asset funding scan." />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th scope="col">#</th>
                  <th scope="col">Market</th>
                  <th scope="col">Venue</th>
                  <th scope="col" className="n">Now ppm/h</th>
                  <th scope="col" className="n">24h avg</th>
                  <th scope="col" className="n">EMA</th>
                  <th scope="col" className="n">Clears gate by</th>
                  <th scope="col">State</th>
                </tr>
              </thead>
              <tbody>
                {items.map((item) => (
                  <tr key={`${item.venue}:${item.asset}`}>
                    <td>{item.rank}</td>
                    <td><strong>{item.asset}</strong></td>
                    <td>{item.venue}</td>
                    <td className="n">{signedPpm(item.fundingRatePpmPerHour)}</td>
                    <td className="n">{signedPpm(item.funding24hAveragePpm)}</td>
                    <td className="n">{signedPpm(item.fundingEmaPpm)}</td>
                    <td className="n">{signedPpm(item.gateDistancePpm)}</td>
                    <td><State eligible={item.eligible} ready={item.historyReady} depth={item.depthQualified} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Panel>

      <Panel
        label="Reverse carry"
        hint="Markets where funding is negative, so shorts pay longs. The strategy takes the long side and borrows to hold spot — worth it only while the receipt beats the borrow rate."
        aside={reverse && <ScanAside at={reverse.asOfMs} gate={`cost gate +${reverse.costThresholdPpm} ppm/h`} />}
      >
        {reverseItems.length === 0 ? (
          <Empty msg="Waiting for qualified negative funding and live Kamino borrow snapshots." />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th scope="col">#</th>
                  <th scope="col">Market</th>
                  <th scope="col">Funding venue</th>
                  <th scope="col" className="n">24h funding</th>
                  <th scope="col">Borrow venue</th>
                  <th scope="col" className="n">Borrow ppm/h</th>
                  <th scope="col" className="n">Utilisation</th>
                  <th scope="col" className="n">Clears gate by</th>
                  <th scope="col">State</th>
                </tr>
              </thead>
              <tbody>
                {reverseItems.map((item) => (
                  <tr key={`${item.venue}:${item.asset}`}>
                    <td>{item.rank}</td>
                    <td><strong>{item.asset}</strong></td>
                    <td>{item.venue}</td>
                    <td className="n">{signedPpm(item.funding24hAveragePpm)}</td>
                    <td>{item.borrowVenue}</td>
                    <td className="n">{item.borrowRatePpmPerHour}</td>
                    <td className="n">{pct(item.borrowUtilizationPpm, 1)}</td>
                    <td className="n">{signedPpm(item.gateDistancePpm)}</td>
                    <td><State eligible={item.eligible} ready={item.historyReady} depth={item.depthQualified} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Panel>

      <Panel
        label="Cross-venue spread"
        hint="The same market on two venues, shorted on one and held long on the other. The edge is the realised funding spread; both legs carry their own margin."
        aside={crossVenue && <ScanAside at={crossVenue.asOfMs} gate={`gate +${crossVenue.gateThresholdPpm} ppm/h`} />}
      >
        {crossVenueItems.length === 0 ? (
          <Empty msg="Waiting for two venues with realised funding, executable depth, and margin evidence." />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th scope="col">#</th>
                  <th scope="col">Market</th>
                  <th scope="col">Short venue</th>
                  <th scope="col">Long venue</th>
                  <th scope="col" className="n">Realised spread</th>
                  <th scope="col" className="n">Clears gate by</th>
                  <th scope="col" className="n">Worst margin</th>
                  <th scope="col">State</th>
                </tr>
              </thead>
              <tbody>
                {crossVenueItems.map((item) => (
                  <tr key={`${item.shortVenue}:${item.longVenue}:${item.asset}`}>
                    <td>{item.rank}</td>
                    <td><strong>{item.asset}</strong></td>
                    <td>{item.shortVenue}</td>
                    <td>{item.longVenue}</td>
                    <td className="n">{signedPpm(item.realizedSpreadPpmPerHour)}</td>
                    <td className="n">{signedPpm(item.gateDistancePpm)}</td>
                    <td className="n">
                      {(Math.min(
                        Number(item.shortMarginRatioPpm),
                        Number(item.longMarginRatioPpm),
                      ) / 1_000_000).toFixed(2)}×
                    </td>
                    <td><State eligible={item.eligible} ready={item.historyReady} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Panel>

    </Section>
  );
}
