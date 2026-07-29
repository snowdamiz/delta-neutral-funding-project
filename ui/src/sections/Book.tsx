import type { Snapshot } from "../api";
import { fmt, shortId } from "../fmt";
import { Chip, Empty, Key, Meter, Panel, Section, proximity } from "../ui";

export function Book({ snap }: { snap: Snapshot }) {
  const { portfolios, positions, config } = snap;
  const band = Number(config?.rebalanceDeltaBps ?? 50);

  const legend = (
    <div className="legend">
      <span><Key variant="sol_control" />SOL control</span>
      <span><Key variant="jitosol_carry" />JitoSOL carry</span>
    </div>
  );

  return (
    <Section n="02" title="Book" note="margin & liquidation headroom vs pinned limits">
      <Panel label="Portfolios & positions" aside={legend}>
        {portfolios.length === 0 ? (
          <Empty msg="no portfolios registered" />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th>Portfolio</th>
                  <th>State</th>
                  <th>Group</th>
                  <th className="n">Capital USD</th>
                  <th className="n">Spot</th>
                  <th className="n">Perp short</th>
                  <th className="n">Net δ SOL</th>
                  <th className="n">δ vs band</th>
                  <th className="n">Collateral USD</th>
                  <th>Margin floor prox.</th>
                  <th>Liq. floor prox.</th>
                </tr>
              </thead>
              <tbody>
                {portfolios.map((p) => {
                  const q = positions.find((x) => x.portfolioRunId === p.id);
                  const m = q?.marginSnapshot;
                  const delta = Number(q?.deltaBps ?? 0);
                  return (
                    <tr key={p.id}>
                      <td>
                        <strong>
                          <Key variant={p.variant} />
                          {shortId(p.id)}
                        </strong>
                      </td>
                      <td><Chip tone={p.state === "idle" ? "mute" : "ok"}>{p.state}</Chip></td>
                      <td><Chip tone="mute">{p.comparisonMode}</Chip></td>
                      <td className="n">{fmt(p.initialCapitalUsd, 2)}</td>
                      <td className="n">{fmt(q?.spotQuantity, 4)}</td>
                      <td className="n">{fmt(q?.perpShortSol, 4)}</td>
                      <td className="n">{fmt(q?.netDeltaSol, 4)}</td>
                      <td className="n">
                        {Math.abs(delta) > band
                          ? <Chip tone="warn">{delta} bps</Chip>
                          : `${delta} bps`}
                      </td>
                      <td className="n">{fmt(m?.collateralUsd, 2)}</td>
                      <td>
                        <Meter
                          p={m ? proximity(m.marginRatioPpm, config?.minimumMarginRatioPpm ?? 0) : null}
                        />
                      </td>
                      <td>
                        <Meter
                          p={
                            m
                              ? proximity(
                                  m.liquidationDistanceBps,
                                  config?.minimumLiquidationDistanceBps ?? 0,
                                )
                              : null
                          }
                        />
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Panel>
    </Section>
  );
}
