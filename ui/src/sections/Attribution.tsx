import type { Pnl, Snapshot } from "../api";
import { fmt, negate, round, shortId } from "../fmt";
import { Empty, Key, Panel, Section } from "../ui";

/**
 * Costs are positive magnitudes in the read model, so the table negates them
 * to make every row read as a sum that arrives at Net.
 */
const COMPONENTS = [
  { k: "fundingRealizedUsd", label: "Funding", color: "var(--ok)", negate: false },
  { k: "basisPnlUsd", label: "Basis", color: "var(--sol)", negate: false },
  { k: "rewardAccrualUsd", label: "Rewards", color: "var(--jito)", negate: false },
  { k: "borrowInterestUsd", label: "Borrow", color: "var(--warn)", negate: true },
  { k: "tradingFeesUsd", label: "Fees", color: "var(--crit)", negate: true },
] as const satisfies ReadonlyArray<{
  k: keyof Pnl;
  label: string;
  color: string;
  negate: boolean;
}>;

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
    <Section
      title="Where the money came from"
      note="Realised cash only. Every row adds up to Net: income in, costs out, no mark-to-market on open positions."
    >
      <Panel
        label="Profit and loss by component"
        hint="Costs are shown negative so each row reads as a sum. The bar under a run name is its composition by magnitude."
        aside={legend}
      >
        {rows.length === 0 ? (
          <Empty msg="No profit or loss recorded yet." />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th>Run</th>
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
                        <Key id={r.variant} />
                        {shortId(r.portfolioRunId)}
                      </strong>
                      <Composition row={r} />
                    </td>
                    {COMPONENTS.map((c) => (
                      <td className="n" key={c.k}>
                        {fmt(c.negate ? negate(r[c.k]) : r[c.k], 2, { signed: true })}
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
