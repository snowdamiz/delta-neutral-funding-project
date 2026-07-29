import type { Snapshot } from "../api";
import { clock, fmt } from "../fmt";
import { Chip, Empty, Key, Panel, Section, variantName } from "../ui";

const micros = (atoms: string) => ({ atoms, scale: 6 });

export function Opportunity({ snap }: { snap: Snapshot }) {
  const items = snap.opportunities;
  return (
    <Section n="05" title="Opportunity" note="entry-gate evaluations, newest first">
      <Panel>
        {items.length === 0 ? (
          <Empty msg="no opportunity evaluations yet" />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th>Variant</th>
                  <th>Gate</th>
                  <th>Reason</th>
                  <th className="n">Net carry USD</th>
                  <th className="n">Exp. funding USD</th>
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
                        <Key variant={o.variant} />
                        {variantName(o.variant)}
                      </strong>
                    </td>
                    <td>
                      {o.eligible
                        ? <Chip tone="ok">eligible</Chip>
                        : <Chip tone="mute">gated</Chip>}
                    </td>
                    <td>{o.reasonCode}</td>
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
