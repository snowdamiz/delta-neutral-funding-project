import { createContext, useContext, useEffect, useState } from "react";
import type { ReactNode } from "react";
import type { Strategy } from "./catalog";
import { accentOf, nameOf } from "./catalog";
import { age } from "./fmt";

export type Tone = "ok" | "warn" | "crit" | "mute";

/** The collector's catalog, so identity primitives never take a props tour. */
const CatalogContext = createContext<Strategy[]>([]);
export const CatalogProvider = CatalogContext.Provider;
export const useCatalog = () => useContext(CatalogContext);

// Status is never carried by colour alone: red↔green is indistinguishable
// under deuteranopia, so every chip pairs a glyph with a word.
const GLYPH: Record<Tone, string> = { ok: "●", warn: "▲", crit: "■", mute: "○" };

export function Chip({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span className={`chip c-${tone}`}>
      <span className="g" aria-hidden="true">{GLYPH[tone]}</span>
      {children}
    </span>
  );
}

/** Series identity: a coloured key beside the name, which is always present. */
export const Key = ({ id }: { id: string }) => (
  <i className="key" style={{ background: accentOf(useCatalog(), id) }} aria-hidden="true" />
);

export const StrategyName = ({ id }: { id: string }) => <>{nameOf(useCatalog(), id)}</>;

/**
 * A 1 Hz clock. Without it every "3s ago" on the page freezes until the next
 * poll lands and then jumps five seconds — which reads as a stalled console,
 * not a live one.
 */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(timer);
  }, [intervalMs]);
  return now;
}

/** In-flight marker. Steady ring at rest, rotating arc while `on`. */
export const Spin = ({ on }: { on?: boolean }) => (
  <i className={on ? "spin on" : "spin"} aria-hidden="true" />
);

/**
 * When something last happened, counting up live. Inside `freshMs` it reads as
 * current and animates; past that it is a plain age. This is the one answer to
 * "is this strategy still being checked, or did it stop?".
 */
export function Since({
  at, verb, freshMs = 30_000,
}: { at: number; verb: string; freshMs?: number }) {
  const now = useNow();
  if (!at) return <span className="since idle"><i className="tick" aria-hidden="true" />{verb} never</span>;
  const elapsed = Math.max(0, now - at);
  const fresh = elapsed < freshMs;
  return (
    <span className={fresh ? "since fresh" : "since"} title={new Date(at).toLocaleString()}>
      <i className="tick" aria-hidden="true" />
      {verb} {elapsed < 2000 ? "just now" : `${age(elapsed)} ago`}
    </span>
  );
}

/**
 * The console's own heartbeat: whether a fetch is in flight, how old the data
 * on screen is, and — via the sweep, restarted by the `key` on each snapshot —
 * how long until the next one. Every number on the page is as old as this says.
 */
export function Live({
  polling, at, reachable, everyMs,
}: { polling: boolean; at: number; reachable: boolean; everyMs: number }) {
  const now = useNow(500);
  const word = !at ? "connecting" : polling ? "fetching" : reachable ? "live" : "unreachable";
  const tone: Tone = !at ? "mute" : reachable ? "ok" : "crit";
  return (
    <span className={`heartbeat t-${tone}${polling ? " busy" : ""}`} role="status" aria-live="polite">
      <Spin on={polling} />
      <span className="w">{word}</span>
      {at > 0 && (
        <span className="ago">{now - at < 1500 ? "just now" : `${age(now - at)} ago`}</span>
      )}
      <span className="sweep" key={at}>
        <i style={{ animationDuration: `${everyMs}ms` }} />
      </span>
    </span>
  );
}

export const reasonName = (reason: string) =>
  ({
    entry_gate_failed: "not profitable",
    non_positive_net_carry: "not profitable after costs",
  })[reason] ?? reason.replaceAll("_", " ");

/**
 * A titled block. `note` is the one-line answer to "what am I looking at" —
 * every section carries one, because a heading like "Attribution" does not
 * survive first contact with someone who did not write the collector.
 */
export function Section({
  title, note, children,
}: { title: string; note?: string; children: ReactNode }) {
  return (
    <section className="rise">
      <div className="shead">
        <h2>{title}</h2>
        <div className="rule" />
      </div>
      {note && <p className="snote">{note}</p>}
      {children}
    </section>
  );
}

export const Panel = ({
  label, hint, aside, children,
}: { label?: string; hint?: string; aside?: ReactNode; children: ReactNode }) => (
  <div className="panel">
    {(label || aside) && (
      <div className="ph">
        <div className="ph-l">
          <span className="lbl">{label}</span>
          {hint && <span className="hint">{hint}</span>}
        </div>
        {aside}
      </div>
    )}
    {children}
  </div>
);

export const Empty = ({ msg }: { msg: string }) => (
  <div className="empty-state">
    <span className="g" aria-hidden="true">◇</span>
    {msg}
  </div>
);

/** The one stat tile. Headline numbers use it big, diagnostics use `sm`. */
export const Stat = ({
  label, value, cap, tone, sm, hero,
}: {
  label: string;
  value: ReactNode;
  cap?: ReactNode;
  tone?: Tone;
  sm?: boolean;
  hero?: boolean;
}) => (
  <div className={`stat${sm ? " sm" : ""}${hero ? " hero" : ""}`}>
    <div className="lbl">{label}</div>
    <div className="val" style={tone ? { color: `var(--${tone})` } : undefined}>{value}</div>
    {cap && <div className="cap">{cap}</div>}
  </div>
);

/**
 * Margin ratio sits ~33x above its floor, so a bar of the raw value would peg
 * at 100% and say nothing. The honest encoding is proximity to the limit —
 * limit/value, clamped — where 0% is maximally safe and 100% is at the floor.
 */
export function proximity(value: string | number, limit: string | number): number | null {
  const v = Number(value);
  const l = Number(limit);
  if (!Number.isFinite(v) || !Number.isFinite(l) || v <= 0) return null;
  return Math.min(l / v, 1);
}

export function Meter({ p }: { p: number | null }) {
  if (p === null) return <span style={{ color: "var(--ink4)" }}>—</span>;
  const tone: Tone = p >= 1 ? "crit" : p > 0.75 ? "warn" : "ok";
  const pct = p * 100;
  return (
    <div
      className="meter"
      role="meter"
      aria-valuenow={Math.round(pct)}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label="proximity to limit"
    >
      <div className="track">
        <div className="bar" style={{ width: `${pct.toFixed(1)}%`, background: `var(--${tone})` }} />
      </div>
      <span className="pct">{pct.toFixed(0)}%</span>
    </div>
  );
}
