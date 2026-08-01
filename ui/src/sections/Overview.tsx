import type { Snapshot } from "../api";
import type { Strategy } from "../catalog";
import { benchmarkRows, familiesOf, netOf } from "../catalog";
import { fmt, micros, ms, sum, toNumber } from "../fmt";
import { freshLimit } from "../status";
import { Chip, Empty, Key, Panel, reasonName, Section, Since, Stat, StrategyName, type Tone } from "../ui";
import { Control } from "./Health";
import { EventFeed } from "./Risk";

const RUN_TONE: Record<string, Tone> = {
  active: "ok",
  paused: "warn",
  idle: "mute",
  unregistered: "mute",
};

const RUN_WORD: Record<string, string> = {
  idle: "no position",
  active: "in position",
  paused: "off",
  unregistered: "not registered",
};

const moneyTone = (n: number): Tone => (n > 0 ? "ok" : n < 0 ? "crit" : "mute");

/**
 * The headline four. None of this existed before: the console showed nine
 * per-strategy cards and left "so how are we doing overall" as an exercise in
 * mental arithmetic.
 */
export function Summary({ snap }: { snap: Snapshot }) {
  const net = sum(...snap.pnl.map((p) => p.netRecordedUsd));
  const paired = snap.strategies.filter((s) => benchmarkRows(snap, s).length > 0);
  const incremental = sum(...paired.map((s) => benchmarkRows(snap, s)[0]?.incremental));
  const holding = snap.portfolios.filter((p) => p.state !== "idle").length;
  const open = snap.events.filter((e) => !e.resolvedAt);
  const critical = open.filter((e) => e.severity === "critical").length;

  return (
    <div className="stats rise">
      <Stat
        hero
        label="Net recorded, all strategies"
        value={<>{fmt(net, 2, { signed: true })}<span className="unit">USD</span></>}
        tone={moneyTone(toNumber(net))}
        cap="Realised cash across every paper run: funding and rewards received, less fees and borrow. No mark-to-market."
      />
      <Stat
        label="Versus benchmarks"
        value={<>{paired.length === 0 ? "—" : fmt(incremental, 2, { signed: true })}<span className="unit">USD</span></>}
        tone={paired.length === 0 ? undefined : moneyTone(toNumber(incremental))}
        cap={
          paired.length === 0
            ? "No strategy is paired with its benchmark yet."
            : `Summed edge over each strategy's declared benchmark, across ${paired.length} paired ${paired.length === 1 ? "strategy" : "strategies"}.`
        }
      />
      <Stat
        label="Holding positions"
        value={<>{holding}<span className="unit">of {snap.portfolios.length}</span></>}
        cap={holding === 0 ? "Nothing is open — no market clears the entry gate." : "Portfolio runs currently hedged."}
      />
      <Stat
        label="Open alerts"
        value={open.length}
        tone={critical > 0 ? "crit" : open.length > 0 ? "warn" : "ok"}
        cap={
          open.length === 0
            ? "Nothing has tripped."
            : `${critical} critical, ${open.length - critical} warning — listed below.`
        }
      />
    </div>
  );
}

function Card({ snap, strategy, onOpen }: { snap: Snapshot; strategy: Strategy; onOpen: () => void }) {
  const s = snap.status;
  const latest = snap.opportunities.find((o) => o.variant === strategy.id);
  const unavailable =
    strategy.id === "cross_venue_funding" &&
      (snap.crossVenueLeaderboard?.items.length ?? 0) === 0
      ? "venue unavailable"
      : strategy.id.startsWith("hyperliquid_wallet_") &&
          (snap.walletTracking?.config?.wallets.length ?? 0) === 0
        ? "wallets not configured"
        : strategy.id === "solana_wallet_flow_quant" &&
            (snap.solanaWalletConfig?.wallets.length ?? 0) === 0
          ? "wallets not configured"
        : "";
  const lead = benchmarkRows(snap, strategy)[0];
  const net = netOf(snap, strategy);
  const controllable =
    !!s && s.deploymentEnvironment === "local" && s.executionMode === "paper" &&
    strategy.runState !== "unregistered" && strategy.controlScope === "strategy";

  const checkedAt = ms(latest?.observedAtMs);

  return (
    <article className="card">
      {/* Remounted whenever this strategy's evaluation timestamp changes, which
          restarts the one-shot flash. That is the whole mechanism: a card that
          lights up is a card the collector just re-priced. */}
      <i className="flash" key={checkedAt} aria-hidden="true" />

      <button type="button" className="open" onClick={onOpen}>
        <span className="who">
          <Key id={strategy.id} />
          <strong><StrategyName id={strategy.id} /></strong>
        </span>
        <span className="micro">Open →</span>
      </button>

      <div className="card-body">
        <div className="lbl">Net recorded</div>
        <div className="big" style={{ color: `var(--${moneyTone(toNumber(net))})` }}>
          {fmt(net, 2, { signed: true })}
          <span className="unit">USD</span>
        </div>
        <div className="cap">
          {lead ? (
            <>
              {fmt(lead.incremental, 2, { signed: true })} USD versus{" "}
              <StrategyName id={strategy.benchmarkStrategyId ?? ""} />
            </>
          ) : strategy.benchmarkStrategyId ? (
            <>Benchmark <StrategyName id={strategy.benchmarkStrategyId} /> — not yet paired</>
          ) : (
            "The standing benchmark other strategies are measured against"
          )}
        </div>

        <div className="card-row">
          <Chip tone={RUN_TONE[strategy.runState] ?? "mute"}>
            {RUN_WORD[strategy.runState] ?? strategy.runState}
          </Chip>
          {latest
            ? <Chip tone={latest.eligible ? "ok" : "mute"}>{latest.eligible ? "entry open" : "gated"}</Chip>
            : <Chip tone="mute">{unavailable || "not evaluated"}</Chip>}
        </div>

        <dl className="card-meta">
          <dt>Legs</dt>
          <dd>{strategy.legs.join(" · ") || "—"}</dd>
          <dt>Gate</dt>
          <dd>
            {latest
              ? `${reasonName(latest.reasonCode)} — ${fmt(micros(latest.netCarryUsdMicros), 4, { signed: true })} USD projected`
              : unavailable || "No market evaluated yet"}
          </dd>
        </dl>

        <div className="card-when">
          <Since at={checkedAt} verb="priced" freshMs={freshLimit(snap)} />
        </div>

        {controllable && <Control paused={!strategy.enabled} strategy={strategy.id} />}
      </div>
    </article>
  );
}

/**
 * Faceted by family. Nine flat cards read as a wall; three groups of three
 * read as a portfolio — and family is the axis the hue already encodes.
 */
export function Overview({ snap, onOpen }: { snap: Snapshot; onOpen: (id: string) => void }) {
  const catalog = snap.strategies;
  const families = familiesOf(catalog);

  return (
    <Section
      title="Strategies"
      note="Strategies start off. Start only the paper strategies you want; each switch is independent."
    >
      {catalog.length === 0 ? (
        <Panel label="Catalog">
          <Empty msg="The collector registered no strategies — /v1/strategies is empty or unreachable." />
        </Panel>
      ) : (
        families.map((family) => {
          const members = catalog.filter((s) => s.family === family);
          return (
            <div className="facet" key={family}>
              <div className="fhead">
                <Key id={members[0]!.id} />
                <h3>{family}</h3>
                <span className="micro">
                  {members.length} {members.length === 1 ? "strategy" : "strategies"}
                </span>
              </div>
              <div className="cards">
                {members.map((s) => (
                  <Card key={s.id} snap={snap} strategy={s} onOpen={() => onOpen(s.id)} />
                ))}
              </div>
            </div>
          );
        })
      )}
    </Section>
  );
}

/** Unresolved alerts, promoted to the landing page — they used to hide inside a strategy. */
export function Alerts({ snap }: { snap: Snapshot }) {
  const open = snap.events.filter((e) => !e.resolvedAt);
  if (open.length === 0) return null;
  return (
    <Section title="Open alerts" note="Unresolved risk events across every strategy. These need a human.">
      <Panel>
        <EventFeed events={open} empty="Nothing has tripped." />
      </Panel>
    </Section>
  );
}
