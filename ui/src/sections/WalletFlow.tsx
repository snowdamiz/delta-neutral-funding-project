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
import { Chip, Empty, Panel, Section, Since, Spin, Stat, type Tone } from "../ui";

const shortMint = (mint: string) => `${mint.slice(0, 4)}…${mint.slice(-4)}`;
const shortWallet = (wallet: string) => `${wallet.slice(0, 6)}…${wallet.slice(-4)}`;
const SOLANA_WALLET = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

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

function Positions({ flow }: { flow: WalletFlowState }) {
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
                  <tr key={position.id}>
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
            tone={gaps.length === 0 ? "ok" : "crit"}
          />
        </div>
      )}

      <Live flow={flow} strategy={strategy} />
      <Positions flow={flow} />
      <Discovery flow={flow} />

      <Panel
        label="Followed wallets"
        hint="The cohort is the strategy's actual edge. Replacing it is atomic, audited, and needs no restart."
        aside={<Since at={ms(cohort.updatedAt)} verb="configured" />}
      >
        <SolanaWalletConfig key={cohort.version} config={cohort} />
      </Panel>

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
                  <tr key={action.id}>
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
    </Section>
  );
}
