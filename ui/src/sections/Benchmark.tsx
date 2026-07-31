import type { Snapshot } from "../api";
import type { Strategy } from "../catalog";
import { benchmarkRows } from "../catalog";
import type { Fixed } from "../fmt";
import { fmt, toNumber } from "../fmt";
import { Empty, Key, Panel, Section, Stat, StrategyName, type Tone } from "../ui";

const Usd = ({ fp }: { fp: Fixed | undefined }) => (
  <>
    {fmt(fp, 2, { signed: true })}
    <span className="unit">USD</span>
  </>
);

const Money = ({ fp, id }: { fp: Fixed | undefined; id: string }) => (
  <span style={{ display: "inline-flex", alignItems: "center" }}>
    <Key id={id} />
    <Usd fp={fp} />
  </span>
);

const moneyTone = (fp: Fixed | undefined): Tone => {
  const n = toNumber(fp);
  return n > 0 ? "ok" : n < 0 ? "crit" : "mute";
};

/**
 * Strategy versus the benchmark it declares in the catalog, per comparison
 * group. The incremental number takes the hero slot because it is the question
 * the comparison exists to answer; which strategies are being compared is data,
 * not copy.
 *
 * `complete` is hardcoded false in the read model — a permanent scope caveat on
 * `recorded_attribution_v1` (realised cash only, no mark-to-market), not a
 * "still computing" flag. It qualifies the numbers rather than suppressing them.
 */
export function Benchmark({ snap, strategy }: { snap: Snapshot; strategy: Strategy }) {
  const benchmarkId = strategy.benchmarkStrategyId;
  const rows = benchmarkRows(snap, strategy);

  if (!benchmarkId) {
    return (
      <Section title="Versus benchmark" note="This strategy declares no benchmark.">
        <Panel label="Comparison">
          <Empty
            msg={`${strategy.displayName} is the standing control that other strategies are measured against, so it has nothing to beat.`}
          />
        </Panel>
      </Section>
    );
  }

  if (rows.length === 0) {
    return (
      <Section title="Versus benchmark" note="Waiting for paired runs.">
        <Panel label="Comparison">
          <Empty msg="No comparison group pairs this strategy with its benchmark yet." />
        </Panel>
      </Section>
    );
  }

  const lead = rows[0]!;

  return (
    <Section
      title="Versus benchmark"
      note="Does this strategy beat the simpler thing it claims to improve on? Realised cash on both sides, same window, no mark-to-market."
    >
      <div className="stats">
        <Stat
          hero
          label={`Edge — ${lead.mode} entry`}
          value={<Usd fp={lead.incremental} />}
          tone={moneyTone(lead.incremental)}
          cap={
            <>
              <StrategyName id={strategy.id} /> net minus <StrategyName id={benchmarkId} /> net.
              Positive means it earned its complexity.
            </>
          }
        />
        <Stat
          label="This strategy"
          value={<Money fp={lead.net} id={strategy.id} />}
          cap={`Recorded net, ${lead.mode} group`}
        />
        <Stat
          label="Benchmark"
          value={<Money fp={lead.benchmarkNet} id={benchmarkId} />}
          cap={`Recorded net, ${lead.mode} group`}
        />
        {rows.slice(1).map((r) => (
          <Stat
            key={r.comparisonGroupId}
            label={`Edge — ${r.mode} entry`}
            value={<Usd fp={r.incremental} />}
            tone={moneyTone(r.incremental)}
            cap="Same comparison, entries timed together instead of independently"
          />
        ))}
      </div>
    </Section>
  );
}
