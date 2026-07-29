import type { Pnl, Snapshot } from "../api";
import type { Fixed } from "../fmt";
import { fmt, round, shortId } from "../fmt";
import { Empty, Key, Panel, Section } from "../ui";

/**
 * The read model computes `net = funding + reward + basis - fees` and reports
 * `tradingFeesUsd` as a positive magnitude. Rendering that magnitude with a `+`
 * would read as a gain, so fees carry `negate` and display as the deduction
 * they are — the row then reads as a sum that arrives at Net.
 */
const COMPONENTS = [
  { k: "fundingRealizedUsd", label: "Funding", color: "var(--ok)", negate: false },
  { k: "basisPnlUsd", label: "Basis", color: "var(--sol)", negate: false },
  { k: "rewardAccrualUsd", label: "Rewards", color: "var(--jito)", negate: false },
  { k: "tradingFeesUsd", label: "Fees", color: "var(--crit)", negate: true },
] as const satisfies ReadonlyArray<{
  k: keyof Pnl;
  label: string;
  color: string;
  negate: boolean;
}>;

const signed = (fp: Fixed, negate: boolean): Fixed =>
  negate && fp.atoms !== "0" ? { ...fp, atoms: (-BigInt(fp.atoms)).toString() } : fp;

/** Magnitudes drive the composition bar; sign stays with the numbers. */
function Composition({ row }: { row: Pnl }) {
  const mags = COMPONENTS.map((c) => Math.abs(Number(round(row[c.k], 6) ?? 0)));
  const total = mags.reduce((a, b) => a + b, 0);
  if (total === 0) return <div className="attr"><span className="empty" /></div>;
  return (
    <div className="attr">
      {COMPONENTS.map((c, i) =>
        mags[i] ? <i key={c.k} style={{ flex: mags[i], background: c.color }} /> : null,
      )}
    </div>
  );
}

export function Attribution({ snap }: { snap: Snapshot }) {
  const rows = snap.pnl;
  const legend = (
    <div className="legend">
      {COMPONENTS.map((c) => (
        <span key={c.k}>
          <i className="key" style={{ background: c.color }} aria-hidden="true" />
          {c.label}
        </span>
      ))}
    </div>
  );

  return (
    <Section n="03" title="Attribution" note="scope: recorded_attribution_v1">
      <Panel label="Realised components per portfolio" aside={legend}>
        {rows.length === 0 ? (
          <Empty msg="no attribution rows" />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th>Portfolio</th>
                  {COMPONENTS.map((c) => (
                    <th className="n" key={c.k}>{c.label} USD</th>
                  ))}
                  <th className="n">Net USD</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.portfolioRunId}>
                    <td>
                      <strong>
                        <Key variant={r.variant} />
                        {shortId(r.portfolioRunId)}
                      </strong>
                      <Composition row={r} />
                    </td>
                    {COMPONENTS.map((c) => (
                      <td className="n" key={c.k}>
                        {fmt(signed(r[c.k], c.negate), 2, { signed: true })}
                      </td>
                    ))}
                    <td className="n">
                      <strong>{fmt(r.netRecordedUsd, 2, { signed: true })}</strong>
                    </td>
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
