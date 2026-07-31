import type { RiskEvent, Snapshot } from "../api";
import { clock, num, pct, shortId } from "../fmt";
import { Chip, Empty, Panel, reasonName, Section, type Tone } from "../ui";

/**
 * Worst first, then newest. The read API returns events newest-first, which
 * buries a critical from an hour ago under a warning from a minute ago — the
 * exact inversion of the order someone scanning for what to fix needs.
 */
const RANK: Record<string, number> = { critical: 0, warning: 1 };
const triage = (a: RiskEvent, b: RiskEvent): number =>
  Number(!!a.resolvedAt) - Number(!!b.resolvedAt) ||
  (RANK[a.severity] ?? 2) - (RANK[b.severity] ?? 2) ||
  Date.parse(b.createdAt) - Date.parse(a.createdAt);

/**
 * The alert list, shared by the overview (where unresolved alerts are the
 * headline) and the per-strategy detail. One markup, so an alert reads the
 * same wherever it surfaces.
 */
export function EventFeed({ events, empty }: { events: RiskEvent[]; empty: string }) {
  return (
    <div className="feed">
      {events.length === 0 ? (
        <Empty msg={empty} />
      ) : (
        [...events].sort(triage).map((e) => {
          const tone: Tone = e.resolvedAt ? "mute" : e.severity === "critical" ? "crit" : "warn";
          return (
            <div className="item" key={e.id}>
              <Chip tone={tone}>{e.resolvedAt ? "resolved" : e.severity}</Chip>
              <div>
                <div className="t">{e.code.replaceAll("_", " ")}</div>
                <div className="d">
                  {e.message}
                  {e.actionTaken && ` · action taken: ${e.actionTaken}`}
                </div>
              </div>
              <span className="ts">{clock(e.createdAt)}</span>
            </div>
          );
        })
      )}
    </div>
  );
}

export function Risk({ snap }: { snap: Snapshot }) {
  const { decisions, events } = snap;
  const unresolved = events.filter((e) => !e.resolvedAt).length;

  return (
    <Section
      title="Risk gate"
      note="Every attempt to open or adjust a position passes the risk gate first. This is what it decided, and anything that has tripped since."
    >
      <div className="cols">
        <Panel
          label="Gate decisions"
          hint="Newest first. “waiting” means the gate saw no reason to act."
          aside={<span className="micro">{decisions.length} shown</span>}
        >
          <div className="feed">
            {decisions.length === 0 ? (
              <Empty msg="No decisions recorded yet." />
            ) : (
              decisions.map((d) => (
                <div className="item" key={d.id}>
                  <Chip tone={d.approved ? "ok" : "mute"}>{d.approved ? d.action : "waiting"}</Chip>
                  <div>
                    <div className="t">{reasonName(d.reasonCode)}</div>
                    <div className="d">
                      {shortId(d.portfolioRunId) || "—"} · margin ratio{" "}
                      {pct(d.healthSnapshot.marginRatioPpm)} · liquidation distance{" "}
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
          label="Alerts"
          hint="Unresolved alerts need a human. Resolved ones are kept for the trail."
          aside={
            <span className="micro">{unresolved ? `${unresolved} unresolved` : "all clear"}</span>
          }
        >
          <EventFeed events={events} empty="Nothing has tripped." />
        </Panel>
      </div>
    </Section>
  );
}
