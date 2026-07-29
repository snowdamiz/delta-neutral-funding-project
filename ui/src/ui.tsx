import type { ReactNode } from "react";
import type { Variant } from "./api";

export type Tone = "ok" | "warn" | "crit" | "mute";

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

export const Key = ({ variant }: { variant: Variant | string }) => (
  <i className={`key ${variant === "jitosol_carry" ? "k-jito" : "k-sol"}`} aria-hidden="true" />
);

export const variantName = (v: Variant | string) =>
  v === "jitosol_carry" ? "JitoSOL carry" : "SOL control";

export function Section({
  n, title, note, children,
}: { n: string; title: string; note?: string; children: ReactNode }) {
  return (
    <section className="rise" style={{ animationDelay: `${Number(n) * 0.05}s` }}>
      <div className="shead">
        <span className="n">{n}</span>
        <h2>{title}</h2>
        <div className="rule" />
        {note && <span className="note">{note}</span>}
      </div>
      {children}
    </section>
  );
}

export const Panel = ({
  label, aside, children,
}: { label?: string; aside?: ReactNode; children: ReactNode }) => (
  <div className="panel">
    {(label || aside) && (
      <div className="ph">
        <span className="lbl">{label}</span>
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
