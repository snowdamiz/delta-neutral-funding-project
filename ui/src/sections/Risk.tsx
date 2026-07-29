import type { Snapshot } from "../api";
import { clock, num, shortId } from "../fmt";
import { Chip, Empty, Panel, Section, type Tone } from "../ui";

const pctFromPpm = (ppm: string) => `${(Number(ppm) / 10000).toFixed(2)}%`;

export function Risk({ snap }: { snap: Snapshot }) {
  const { decisions, events } = snap;
  const unresolved = events.filter((e) => !e.resolvedAt).length;

  return (
    <Section n="04" title="Risk" note="gate decisions & unresolved events">
      <div className="cols">
        <Panel label="Decisions" aside={<span className="micro">{decisions.length} shown</span>}>
          <div className="feed">
            {decisions.length === 0 ? (
              <Empty msg="no risk decisions recorded" />
            ) : (
              decisions.map((d) => (
                <div className="item" key={d.id}>
                  <Chip tone={d.approved ? "ok" : "mute"}>{d.action}</Chip>
                  <div>
                    <div className="t">{d.reasonCode}</div>
                    <div className="d">
                      {shortId(d.portfolioRunId) || "—"} · margin{" "}
                      {pctFromPpm(d.healthSnapshot.marginRatioPpm)} · liq{" "}
                      {num(d.healthSnapshot.liquidationDistanceBps)} bps
                      {d.healthSnapshot.oracleValid === false && " · ORACLE INVALID"}
                    </div>
                  </div>
                  <span className="ts">{clock(d.createdAt)}</span>
                </div>
              ))
            )}
          </div>
        </Panel>

        <Panel
          label="Events"
          aside={<span className="micro">{unresolved ? `${unresolved} unresolved` : "all resolved"}</span>}
        >
          <div className="feed">
            {events.length === 0 ? (
              <Empty msg="no risk events — nothing has tripped" />
            ) : (
              events.map((e) => {
                const tone: Tone = e.resolvedAt
                  ? "mute"
                  : e.severity === "critical"
                    ? "crit"
                    : "warn";
                return (
                  <div className="item" key={e.id}>
                    <Chip tone={tone}>{e.severity}</Chip>
                    <div>
                      <div className="t">{e.code}</div>
                      <div className="d">
                        {e.message}
                        {e.actionTaken && ` · action: ${e.actionTaken}`}
                        {e.resolvedAt && " · resolved"}
                      </div>
                    </div>
                    <span className="ts">{clock(e.createdAt)}</span>
                  </div>
                );
              })
            )}
          </div>
        </Panel>
      </div>
    </Section>
  );
}
