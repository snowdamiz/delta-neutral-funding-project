import { useState } from "react";
import { control, type Snapshot } from "../api";
import { age, fmt, num } from "../fmt";
import { health } from "../status";
import { Chip, Panel, Section, Stat } from "../ui";

/**
 * The one paper control. `strategy` scopes it to the card it was pressed from:
 * the signing proxy carries it into the operator command's reason, so the
 * evidence trail records which strategy the operator acted on even while the
 * collector's own pause state is a singleton.
 */
export function Control({ paused, strategy }: { paused: boolean; strategy?: string }) {
  const [busy, setBusy] = useState(false);
  const [feedback, setFeedback] = useState("");

  const press = async () => {
    setBusy(true);
    setFeedback("");
    try {
      await control(paused ? "resume" : "pause-all", strategy);
      setFeedback(paused ? "Entries resumed." : "Entries halted.");
    } catch (error) {
      setFeedback(error instanceof Error ? error.message : "Operator request failed.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="controls">
      <button type="button" className={paused ? "go" : ""} onClick={press} disabled={busy}>
        {busy ? "Working…" : paused ? "Start entries" : "Stop entries"}
      </button>
      <span role="status">
        {feedback || (paused ? "Resumes opening new positions." : "Halts new positions; open ones keep settling.")}
      </span>
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
  const maxAge = Number(cfg?.maxSourceAgeMs ?? 60000);
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
        <Panel label="Operator control" hint="Collector-wide. Paper mode, local deployment — no signer route exists.">
          <div className="pad">
            <Control paused={s.paused || s.pauseAll || s.pauseEntries} />
          </div>
        </Panel>
      )}
    </Section>
  );
}
