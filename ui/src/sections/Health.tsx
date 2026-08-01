import { useState } from "react";
import { DATABASE_RESET_APPROVAL } from "../../reset";
import { control, resetDatabase, type Snapshot } from "../api";
import { age, fmt, latest, ms, num } from "../fmt";
import { freshLimit, health } from "../status";
import { Chip, Panel, Section, Since, Spin, Stat } from "../ui";

/**
 * One button serves the collector-wide emergency switch and each independent
 * strategy switch. The path, labels, and feedback follow the supplied scope.
 */
export function Control({
  paused,
  strategy,
  disabledReason,
}: {
  paused: boolean;
  strategy?: string;
  disabledReason?: string;
}) {
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");
  const scoped = strategy !== undefined;

  const press = async () => {
    setBusy(true);
    setFeedback("");
    try {
      await control(strategy ? paused ? "start" : "stop" : paused ? "resume" : "pause-all", strategy);
      setFeedback(scoped
        ? paused ? "Strategy started." : "Strategy stopped."
        : paused ? "Entries resumed." : "Entries halted.");
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : "Operator request failed.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="controls">
      <button
        type="button"
        className={paused ? "go" : ""}
        onClick={press}
        disabled={busy || (paused && disabledReason !== undefined)}
        aria-busy={busy}
      >
        {busy && <Spin on />}
        {busy ? "Sending…" : paused ? scoped ? "Start strategy" : "Start entries" : scoped ? "Stop strategy" : "Stop entries"}
      </button>
      <span role="status">
        {busy
          ? `Waiting for the collector to acknowledge ${paused ? "start" : "stop"}…`
          : feedback || (paused
            ? scoped ? disabledReason || "Allows this strategy to open positions." : "Resumes opening new positions."
            : "Halts new positions; open ones keep settling.")}
      </span>
    </div>
  );
}

export function DatabaseReset() {
  const [approval, setApproval] = useState("");
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setFeedback("Stopping the stack, clearing PostgreSQL, and restarting operations…");
    try {
      await resetDatabase(approval);
      setApproval("");
      setFeedback("Paper database cleared. Operations restarted.");
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : "Database reset failed.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="database-reset" onSubmit={submit}>
      <label htmlFor="database-reset-approval">
        Type <code>{DATABASE_RESET_APPROVAL}</code> to permanently delete all paper data.
      </label>
      <div>
        <input
          id="database-reset-approval"
          value={approval}
          onChange={(event) => setApproval(event.target.value)}
          autoComplete="off"
          spellCheck={false}
        />
        <button
          type="submit"
          disabled={busy || approval !== DATABASE_RESET_APPROVAL}
          aria-busy={busy}
        >
          {busy ? "Restarting…" : "Wipe database and restart"}
        </button>
      </div>
      <span role="status">{feedback || "The deleted paper ledger cannot be recovered."}</span>
    </form>
  );
}

/**
 * The collector's work loop, as live counters. A dashboard of final numbers
 * cannot distinguish "nothing is happening because nothing qualifies" from
 * "nothing is happening because the loop died" — these can, because they count
 * up when work stops and reset when it does not.
 */
export function Activity({ snap }: { snap: Snapshot }) {
  const feedAgeMs = Number(snap.adapter?.latest?.ageMs ?? NaN);
  // The feed's own freshness limit is the honest threshold for the loop that
  // runs on every tick: inside it the collector is working, past it it is not.
  const fresh = freshLimit(snap);
  const scans = [
    snap.fundingLeaderboard?.asOfMs,
    snap.reverseCarryLeaderboard?.asOfMs,
    snap.crossVenueLeaderboard?.asOfMs,
  ];

  return (
    <div className="activity rise" aria-label="Recent collector activity">
      <span className="lbl">Activity</span>
      <Since
        at={Number.isFinite(feedAgeMs) && snap.polledAt ? snap.polledAt - feedAgeMs : 0}
        verb="market tick"
        freshMs={fresh}
      />
      <Since at={scans.reduce<number>((max, v) => Math.max(max, ms(v)), 0)} verb="scan" freshMs={fresh} />
      <Since at={latest(snap.opportunities, (o) => o.observedAtMs)} verb="priced" freshMs={fresh} />
      <Since at={latest(snap.decisions, (d) => d.createdAt)} verb="risk check" freshMs={fresh} />
      <Since at={latest(snap.orders, (o) => o.createdAt)} verb="order" freshMs={60_000} />
      <Since at={latest(snap.fills, (f) => f.createdAt)} verb="fill" freshMs={60_000} />
      <Since at={latest(snap.funding, (f) => f.effectiveAtMs)} verb="funding" freshMs={60_000} />
    </div>
  );
}

/**
 * The lede: one word for the state, one sentence for what it means, and the
 * control that changes it — all above the fold, on the default tab.
 */
export function StatusBanner({ snap }: { snap: Snapshot }) {
  const h = health(snap);
  return (
    <>
      <div className="banner rise" style={{ ["--st" as string]: `var(--${h.tone})` }}>
        <div className="banner-l">
          <div className="state">{h.word}</div>
          <div>
            <p className="state-sub">{h.detail}</p>
            {h.extra && <p className="state-extra">{h.extra}</p>}
          </div>
        </div>
        {h.controllable && <Control paused={h.paused} />}
      </div>
      <Activity snap={snap} />
    </>
  );
}

/**
 * Domain semantics matter here, and they are counter-intuitive enough to need
 * saying out loud on the surface: in paper mode an unreachable signer and
 * `liveEnabled: false` are the safety invariants *holding*, not faults. The
 * grouping and the hint above each group carry that; a bare green chip next to
 * the word "isolated" does not.
 */
export function SystemHealth({ snap }: { snap: Snapshot }) {
  const { status: s, config: cfg, adapter, executor, reconciliation, build } = snap;

  if (!s) {
    return (
      <Section title="System health" note="The collector is not answering, so there is nothing to report.">
        <Panel label="Connection">
          <div className="empty-state">
            <span className="g" aria-hidden="true">◇</span>
            No response from the collector. Bring the stack up with <code>docker compose up</code>.
          </div>
        </Panel>
      </Section>
    );
  }

  const ageMs = Number(adapter?.latest?.ageMs ?? NaN);
  const maxAge = freshLimit(snap);
  const stale = Number.isFinite(ageMs) && ageMs > maxAge;
  const leaseLost = s.pauseReason === "leader_lease_lost";

  return (
    <Section
      title="System health"
      note={`${s.deploymentEnvironment} deployment, ${s.executionMode} execution — control plane version ${s.controlVersion}.`}
    >
      <Panel
        label="Safety interlocks"
        hint="Green means locked down. This build cannot move real money, and these four are how you confirm it."
      >
        <div className="grid">
          <Stat
            sm
            label="Execution mode"
            value={<Chip tone={s.executionMode === "paper" ? "ok" : "crit"}>{s.executionMode}</Chip>}
            cap={s.executionMode === "paper" ? "Simulated fills only" : "REAL ORDERS — verify intent"}
          />
          <Stat
            sm
            label="Live execution"
            value={<Chip tone={cfg?.liveEnabled ? "crit" : "ok"}>{cfg?.liveEnabled ? "enabled" : "disabled"}</Chip>}
            cap="Pinned config flag, not a runtime toggle"
          />
          <Stat
            sm
            label="Signer"
            value={<Chip tone={s.signerReachable ? "crit" : "ok"}>{s.signerReachable ? "reachable" : "isolated"}</Chip>}
            cap="Isolated is correct — no key material on this host"
          />
          <Stat
            sm
            label="Executor"
            value={<Chip tone={executor?.enabled ? "warn" : "ok"}>{executor?.enabled ? "enabled" : "not installed"}</Chip>}
            cap={`Policy ${executor?.policyVersion ?? "—"}`}
          />
        </div>
      </Panel>

      <Panel
        label="Market data"
        hint={`Entries gate off automatically once the feed passes ${num(maxAge / 1000)}s old.`}
        aside={
          <Since
            at={Number.isFinite(ageMs) && snap.polledAt ? snap.polledAt - ageMs : 0}
            verb="last tick"
            freshMs={maxAge}
          />
        }
      >
        <div className="grid">
          <Stat
            sm
            label="Feed freshness"
            value={
              <Chip tone={stale ? "warn" : adapter?.latest ? "ok" : "mute"}>
                {stale ? "stale" : adapter?.latest ? "fresh" : "no data"}
              </Chip>
            }
            cap={adapter?.latest ? `${age(ageMs)} old · limit ${num(maxAge / 1000)}s` : "No snapshot received yet"}
          />
          <Stat
            sm
            label="Source"
            value={<span className="num sm">{adapter?.mode ?? "—"}</span>}
            cap={
              adapter?.latest
                ? `Slot ${num(adapter.latest.sourceSlot)} · sequence ${adapter.latest.sourceSequence}`
                : "—"
            }
          />
          <Stat
            sm
            label="Adapter mode"
            value={<span className="num sm">{cfg?.adapterMode ?? "—"}</span>}
            cap={`Emits every ${num((Number(cfg?.emitIntervalMs) || 0) / 1000)}s`}
          />
        </div>
      </Panel>

      <Panel
        label="Coordination and consistency"
        hint="Exactly one instance may write. If the lease is lost, every entry fails closed until it is regained."
      >
        <div className="grid">
          <Stat
            sm
            label="Writer lease"
            value={
              <Chip tone={leaseLost ? "crit" : s.leaderLeaseHolder ? "ok" : "mute"}>
                {leaseLost ? "lost" : s.leaderLeaseHolder ? "held" : "none"}
              </Chip>
            }
            cap={`${s.leaderLeaseHolder ?? "nobody"} · generation ${s.leaderLeaseGeneration}`}
          />
          <Stat
            sm
            label="Reconciliation"
            value={
              reconciliation
                ? <Chip tone={reconciliation.result === "matched" ? "ok" : "crit"}>{reconciliation.result}</Chip>
                : <Chip tone="mute">never run</Chip>
            }
            cap={reconciliation ? `${reconciliation.differences.length} difference(s) found` : "No reconciliation recorded"}
          />
          <Stat
            sm
            label="Shutdown"
            value={<Chip tone={s.shutdownRequested ? "warn" : "ok"}>{s.shutdownRequested ? "requested" : "nominal"}</Chip>}
            cap={`Live notional ${fmt(s.liveNotional, 2)} USD`}
          />
          <Stat
            sm
            label="Build"
            value={<span className="num sm">{build?.codeCommit?.slice(0, 12) ?? "—"}</span>}
            cap={`Mesh ${build?.meshCommit?.slice(0, 8) ?? "—"} · schema v${build?.schemaVersion ?? "—"}`}
          />
        </div>
      </Panel>

      {s.deploymentEnvironment === "local" && s.executionMode === "paper" && (
        <>
          <Panel label="Operator control" hint="Collector-wide. Paper mode, local deployment — no signer route exists.">
            <div className="pad">
              <Control paused={s.paused || s.pauseAll || s.pauseEntries} />
            </div>
          </Panel>
          <Panel
            label="Reset paper database"
            hint="Starts a brand-new paper ledger, reapplies migrations, and restarts the collector and adapter."
          >
            <DatabaseReset />
          </Panel>
        </>
      )}
    </Section>
  );
}
