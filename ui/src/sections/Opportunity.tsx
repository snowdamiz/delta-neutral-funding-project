import type { Snapshot } from "../api";
import { clock, fmt, micros } from "../fmt";
import { Chip, Empty, Key, Panel, reasonName, Section, StrategyName } from "../ui";

export function Opportunity({ snap }: { snap: Snapshot }) {
  const items = snap.opportunities;
  const holdHours = Number(snap.config?.expectedHoldHours ?? 72);
  const breakEvenHours = Number(snap.config?.maximumBreakEvenHours ?? 48);
  return (
    <Section
      title="Entry evaluations"
      note={`Each time the market moves, the collector prices the trade over a ${holdHours}h hold after all costs. It enters only if that is positive and entry costs break even inside ${breakEvenHours}h.`}
    >
      <Panel label="Recent evaluations" hint="Newest first. “Gated” means the trade was priced and refused, not that it was missed.">
        {items.length === 0 ? (
          <Empty msg="No market has been evaluated yet." />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th>Strategy</th>
                  <th>Outcome</th>
                  <th>Reason</th>
                  <th className="n">Projected net USD</th>
                  <th className="n">Funding USD</th>
                  <th className="n">NAV reward USD</th>
                  <th className="n">Hedge SOL</th>
                  <th>Observed</th>
                </tr>
              </thead>
              <tbody>
                {items.map((o) => (
                  <tr key={o.id}>
                    <td>
                      <strong>
                        <Key id={o.variant} />
                        <StrategyName id={o.variant} />
                      </strong>
                    </td>
                    <td>
                      {o.eligible
                        ? <Chip tone="ok">would enter</Chip>
                        : <Chip tone="mute">gated</Chip>}
                    </td>
                    <td>{reasonName(o.reasonCode)}</td>
                    <td className="n">{fmt(micros(o.netCarryUsdMicros), 4, { signed: true })}</td>
                    <td className="n">{fmt(micros(o.expectedFundingUsdMicros), 4, { signed: true })}</td>
                    <td className="n">{fmt(micros(o.navRewardUsdMicros), 4, { signed: true })}</td>
                    <td className="n">{fmt({ atoms: o.hedgeLamports, scale: 9 }, 4)}</td>
                    <td>{clock(Number(o.observedAtMs))}</td>
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
