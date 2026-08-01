import { type Snapshot } from "../api";
import { ms, pct } from "../fmt";
import { Chip, Empty, Panel, Section, Since } from "../ui";

const signedPpm = (value: string) => `${Number(value) >= 0 ? "+" : ""}${value}`;

/** Each scan's own clock, beside its gate. A stale table and a quiet market
 *  look identical without it. */
const ScanAside = ({ at, gate }: { at: string | undefined; gate?: string }) => (
  <span className="scan-aside">
    {gate && <span className="micro">{gate}</span>}
    <Since at={ms(at)} verb="scanned" />
  </span>
);

/** Every scan table ends in the same three-state verdict, so it renders once. */
const State = ({ eligible, ready, depth = true }: { eligible: boolean; ready: boolean; depth?: boolean }) => (
  <Chip tone={eligible ? "ok" : ready ? "warn" : "mute"}>
    {eligible ? "clears gate" : !depth ? "no executable route" : ready ? "below gate" : "warming up"}
  </Chip>
);

/**
 * What the collector can see, before any strategy acts on it. The two carry
 * scans live here; the wallet-flow strategy carries its own market view inside
 * its detail page.
 */
export function Markets({ snap }: { snap: Snapshot }) {
  const funding = snap.fundingLeaderboard;
  const items = funding?.items ?? [];
  const reverse = snap.reverseCarryLeaderboard;
  const reverseItems = reverse?.items ?? [];

  return (
    <Section
      title="Market scans"
      note="Continuous scans across venues. A market has to clear its gate here before any strategy will open a position — rates are in parts per million per hour (ppm/h)."
    >
      <Panel
        label="Funding rates"
        hint="Funding paid to shorts. The carry strategies enter when a market beats the gate and stays there."
        aside={funding && <ScanAside at={funding.asOfMs} gate={`gate ${signedPpm(funding.gateThresholdPpm)} ppm/h`} />}
      >
        {items.length === 0 ? (
          <Empty msg="Waiting for the first complete cross-asset funding scan." />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th scope="col">#</th>
                  <th scope="col">Market</th>
                  <th scope="col">Venue</th>
                  <th scope="col" className="n">Now ppm/h</th>
                  <th scope="col" className="n">24h avg</th>
                  <th scope="col" className="n">EMA</th>
                  <th scope="col" className="n">Clears gate by</th>
                  <th scope="col">State</th>
                </tr>
              </thead>
              <tbody>
                {items.map((item) => (
                  <tr key={`${item.venue}:${item.asset}`}>
                    <td>{item.rank}</td>
                    <td><strong>{item.asset}</strong></td>
                    <td>{item.venue}</td>
                    <td className="n">{signedPpm(item.fundingRatePpmPerHour)}</td>
                    <td className="n">{signedPpm(item.funding24hAveragePpm)}</td>
                    <td className="n">{signedPpm(item.fundingEmaPpm)}</td>
                    <td className="n">{signedPpm(item.gateDistancePpm)}</td>
                    <td><State eligible={item.eligible} ready={item.historyReady} depth={item.depthQualified} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Panel>

      <Panel
        label="Reverse carry"
        hint="Markets where funding is negative, so shorts pay longs. The strategy takes the long side and borrows to hold spot — worth it only while the receipt beats the borrow rate."
        aside={reverse && <ScanAside at={reverse.asOfMs} gate={`cost gate +${reverse.costThresholdPpm} ppm/h`} />}
      >
        {reverseItems.length === 0 ? (
          <Empty msg="Waiting for qualified negative funding and live Kamino borrow snapshots." />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th scope="col">#</th>
                  <th scope="col">Market</th>
                  <th scope="col">Funding venue</th>
                  <th scope="col" className="n">24h funding</th>
                  <th scope="col">Borrow venue</th>
                  <th scope="col" className="n">Borrow ppm/h</th>
                  <th scope="col" className="n">Utilisation</th>
                  <th scope="col" className="n">Clears gate by</th>
                  <th scope="col">State</th>
                </tr>
              </thead>
              <tbody>
                {reverseItems.map((item) => (
                  <tr key={`${item.venue}:${item.asset}`}>
                    <td>{item.rank}</td>
                    <td><strong>{item.asset}</strong></td>
                    <td>{item.venue}</td>
                    <td className="n">{signedPpm(item.funding24hAveragePpm)}</td>
                    <td>{item.borrowVenue}</td>
                    <td className="n">{item.borrowRatePpmPerHour}</td>
                    <td className="n">{pct(item.borrowUtilizationPpm, 1)}</td>
                    <td className="n">{signedPpm(item.gateDistancePpm)}</td>
                    <td><State eligible={item.eligible} ready={item.historyReady} depth={item.depthQualified} /></td>
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
