import type { ReactNode } from "react";
import type { Snapshot } from "../api";
import { age, fmt, num } from "../fmt";
import { Chip, Section, type Tone } from "../ui";

const Cell = ({ label, value, foot }: { label: string; value: ReactNode; foot?: ReactNode }) => (
  <div>
    <div className="lbl">{label}</div>
    <div className="v">{value}</div>
    {foot && <div className="foot">{foot}</div>}
  </div>
);

/**
 * Domain semantics matter here. In paper mode an unreachable signer and
 * `liveEnabled: false` are the safety invariants *holding*, not faults — so
 * they read green. What is a genuine fault is a lost writer lease (no instance
 * is authoritative) or a market feed older than `maxSourceAgeMs`.
 */
export function Signal({ snap }: { snap: Snapshot }) {
  const { status: s, config: cfg, adapter, executor, reconciliation } = snap;

  if (!s) {
    return (
      <Section n="00" title="Signal" note="no contact">
        <div className="hero" style={{ ["--st" as string]: "var(--crit)" }}>
          <div className="left">
            <div className="state">OFFLINE</div>
            <div className="state-sub">
              collector unreachable — is the stack up? <code>docker compose up</code>
            </div>
          </div>
          <div className="diag" />
        </div>
      </Section>
    );
  }

  const ageMs = Number(adapter?.latest?.ageMs ?? NaN);
  const maxAge = Number(cfg?.maxSourceAgeMs ?? 60000);
  const stale = Number.isFinite(ageMs) && ageMs > maxAge;
  const paused = s.paused || s.pauseAll;

  let tone: Tone = "ok";
  let word = "ARMED";
  let sub: ReactNode = (
    <>
      {num(s.activePortfolios)} portfolio(s) active · lease held by{" "}
      <code>{s.leaderLeaseHolder ?? "—"}</code>
    </>
  );

  if (paused) {
    tone = s.pauseReason === "leader_lease_lost" ? "crit" : "warn";
    word = "PAUSED";
    sub = (
      <>
        entries halted — reason <code>{s.pauseReason ?? "unspecified"}</code>
        {s.pauseReason === "leader_lease_lost" && (
          <>
            <br />
            writer lease held by <code>{s.leaderLeaseHolder ?? "nobody"}</code> at generation{" "}
            {s.leaderLeaseGeneration}. No instance is authoritative, so every entry fails closed.
          </>
        )}
      </>
    );
  } else if (stale) {
    tone = "warn";
    word = "STALE";
    sub = (
      <>
        market feed is {age(ageMs)} old against a {num(maxAge / 1000)}s limit — entries will gate off
      </>
    );
  }

  return (
    <Section
      n="00"
      title="Signal"
      note={`${s.deploymentEnvironment} · control v${s.controlVersion}`}
    >
      <div className="hero" style={{ ["--st" as string]: `var(--${tone})` }}>
        <div className="left">
          <div className="state">{word}</div>
          <div className="state-sub">{sub}</div>
        </div>
        <div className="diag">
          <Cell
            label="Execution mode"
            value={<Chip tone={s.executionMode === "paper" ? "ok" : "crit"}>{s.executionMode}</Chip>}
            foot={cfg ? `live execution ${cfg.liveEnabled ? "ENABLED" : "disabled"}` : null}
          />
          <Cell
            label="Signer"
            value={
              <Chip tone={s.signerReachable ? "crit" : "ok"}>
                {s.signerReachable ? "reachable" : "isolated"}
              </Chip>
            }
            foot="no key material on this host"
          />
          <Cell
            label="Market feed"
            value={
              <Chip tone={stale ? "warn" : adapter?.latest ? "ok" : "mute"}>
                {stale ? "stale" : adapter?.latest ? "fresh" : "no data"}
              </Chip>
            }
            foot={
              adapter?.latest
                ? `${age(ageMs)} old · limit ${num(maxAge / 1000)}s`
                : "no snapshot received"
            }
          />
          <Cell
            label="Source"
            value={<span className="num" style={{ fontSize: 13 }}>{adapter?.mode ?? "—"}</span>}
            foot={
              adapter?.latest
                ? `slot ${num(adapter.latest.sourceSlot)} · seq ${adapter.latest.sourceSequence}`
                : null
            }
          />
          <Cell
            label="Adapter mode"
            value={<span className="num" style={{ fontSize: 13 }}>{cfg?.adapterMode ?? "—"}</span>}
            foot={`emit every ${num((Number(cfg?.emitIntervalMs) || 0) / 1000)}s`}
          />
          <Cell
            label="Executor"
            value={
              <Chip tone={executor?.enabled ? "warn" : "ok"}>
                {executor?.enabled ? "enabled" : "not installed"}
              </Chip>
            }
            foot={`policy ${executor?.policyVersion ?? "—"}`}
          />
          <Cell
            label="Reconciliation"
            value={
              reconciliation ? (
                <Chip tone={reconciliation.result === "matched" ? "ok" : "crit"}>
                  {reconciliation.result}
                </Chip>
              ) : (
                <Chip tone="mute">none</Chip>
              )
            }
            foot={
              reconciliation
                ? `${reconciliation.differences.length} difference(s)`
                : null
            }
          />
          <Cell
            label="Shutdown"
            value={
              <Chip tone={s.shutdownRequested ? "warn" : "ok"}>
                {s.shutdownRequested ? "requested" : "nominal"}
              </Chip>
            }
            foot={`live notional ${fmt(s.liveNotional, 2)} USD`}
          />
        </div>
      </div>
    </Section>
  );
}
