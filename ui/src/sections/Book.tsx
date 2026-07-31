import type { Snapshot } from "../api";
import { fmt, shortId } from "../fmt";
import { Chip, Empty, Key, Meter, Panel, Section, StrategyName, proximity, useCatalog } from "../ui";

export function Book({ snap }: { snap: Snapshot }) {
  const { portfolios, positions, config } = snap;
  const band = Number(config?.rebalanceDeltaBps ?? 50);
  const shown = useCatalog().filter((s) => portfolios.some((p) => p.variant === s.id));

  const legend = (
    <div className="legend">
      {shown.map((s) => (
        <span key={s.id}><Key id={s.id} /><StrategyName id={s.id} /></span>
      ))}
    </div>
  );

  return (
    <Section
      title="Positions"
      note="Each strategy runs the same book twice — once entering independently, once entering in step with its benchmark. Delta is the residual exposure the hedge has not cancelled."
    >
      <Panel
        label="Portfolio runs"
        hint="The two meters read distance to a floor: 0% is maximum headroom, 100% is sitting on the limit."
        aside={legend}
      >
        {portfolios.length === 0 ? (
          <Empty msg="No portfolio runs registered." />
        ) : (
          <div className="tw">
            <table>
              <thead>
                <tr>
                  <th>Run</th>
                  <th>State</th>
                  <th>Entry timing</th>
                  <th>Asset</th>
                  <th className="n">Capital USD</th>
                  <th className="n">Spot held</th>
                  <th className="n">Perp short</th>
                  <th className="n">Net delta</th>
                  <th className="n">vs {band} bps band</th>
                  <th className="n">Collateral USD</th>
                  <th>Margin headroom</th>
                  <th>Liquidation headroom</th>
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
                          <Key id={p.variant} />
                          {shortId(p.id)}
                        </strong>
                      </td>
                      <td>
                        <Chip tone={p.state === "idle" ? "mute" : "ok"}>
                          {p.state === "idle" ? "no position" : p.state}
                        </Chip>
                      </td>
                      <td><Chip tone="mute">{p.comparisonMode}</Chip></td>
                      <td>{q?.asset || "—"}</td>
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
