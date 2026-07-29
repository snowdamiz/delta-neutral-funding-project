import type { ReactNode } from "react";
import type { Fixed } from "../fmt";
import type { Snapshot } from "../api";
import { fmt } from "../fmt";
import { Key, Section } from "../ui";

const Tile = ({
  label, value, cap, hero,
}: { label: string; value: ReactNode; cap: string; hero?: boolean }) => (
  <div className={`kpi${hero ? " hero-kpi" : ""}`}>
    <div className="lbl">{label}</div>
    <div className="val">{value}</div>
    <div className="cap">{cap}</div>
  </div>
);

const Pending = () => <span className="pending">PENDING</span>;

const Money = ({ fp, variant }: { fp: Fixed | undefined; variant: string }) => (
  <span style={{ display: "inline-flex", alignItems: "center" }}>
    <Key variant={variant} />
    {fmt(fp, 2, { signed: true })}
    <span className="unit">USD</span>
  </span>
);

/**
 * The incremental number is the entire reason this project exists, so it takes
 * the hero slot.
 *
 * `complete` is hardcoded false in the read model — it is a permanent scope
 * caveat on `recorded_attribution_v1` (realised cash only, no mark-to-market),
 * not a "still computing" flag. So it qualifies the numbers rather than
 * suppressing them; gating on it would hide the headline metric forever.
 * PENDING is reserved for genuinely absent data.
 */
export function Thesis({ snap }: { snap: Snapshot }) {
  const ind = snap.comparison.find((c) => c.mode === "independent");
  const syn = snap.comparison.find((c) => c.mode === "synchronized");
  const hasData = snap.comparison.length > 0;

  const usd = (fp: Fixed | undefined) =>
    hasData ? (
      <>
        {fmt(fp, 2, { signed: true })}
        <span className="unit">USD</span>
      </>
    ) : (
      <Pending />
    );

  return (
    <Section n="01" title="Thesis" note="recorded attribution — realised only, no mark-to-market">
      <div className="kpis">
        <Tile
          hero
          label="JitoSOL incremental — independent"
          value={usd(ind?.jitosolIncrementalNetRecordedUsd)}
          cap={
            hasData
              ? "JitoSOL carry net minus SOL control net. Positive means the staking yield survived the hedge."
              : "No comparison groups reported yet."
          }
        />
        <Tile
          label="SOL control net"
          value={hasData ? <Money fp={ind?.solNetRecordedUsd} variant="sol_control" /> : <Pending />}
          cap="independent group, recorded"
        />
        <Tile
          label="JitoSOL carry net"
          value={
            hasData ? <Money fp={ind?.jitosolNetRecordedUsd} variant="jitosol_carry" /> : <Pending />
          }
          cap="independent group, recorded"
        />
        <Tile
          label="Synchronized incremental"
          value={usd(syn?.jitosolIncrementalNetRecordedUsd)}
          cap="same comparison under paired entry timing"
        />
      </div>
    </Section>
  );
}
