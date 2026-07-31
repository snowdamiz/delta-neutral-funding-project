import type { Snapshot } from "../api";
import { ownerOf } from "../catalog";
import { clock, fmt, shortId } from "../fmt";
import { Chip, Empty, Key, Panel, Section, useCatalog, type Tone } from "../ui";

const ORDER_TONE: Record<string, Tone> = {
  FILLED: "ok",
  PARTIAL: "warn",
  REJECTED: "crit",
  UNKNOWN: "crit",
};

export function Ledger({ snap }: { snap: Snapshot }) {
  const { orders, fills, funding } = snap;
  const catalog = useCatalog();

  return (
    <Section
      title="Execution record"
      note="What was submitted, what filled, and what funding settled. Simulated throughout — no order here reached a venue."
    >
      <div className="cols-3">
        <Panel label="Orders" hint="Submitted intents and their fill progress.">
          <div className="feed">
            {orders.length === 0 ? (
              <Empty msg="Nothing has been submitted." />
            ) : (
              orders.map((o) => (
                <div className="item" key={o.id}>
                  <Chip tone={ORDER_TONE[o.status] ?? "mute"}>{o.status}</Chip>
                  <div>
                    <div className="t">
                      <Key id={o.variant} />
                      {o.intent?.instrument ?? o.intentId}
                    </div>
                    <div className="d">
                      {o.intent?.leg} · {fmt(o.filledQuantity, 4)} / {fmt(o.requestedQuantity, 4)}
                    </div>
                  </div>
                  <span className="ts">{clock(o.createdAt)}</span>
                </div>
              ))
            )}
          </div>
        </Panel>

        <Panel label="Fills" hint="Simulated executions at the modelled price and fee.">
          <div className="feed">
            {fills.length === 0 ? (
              <Empty msg="No fills recorded." />
            ) : (
              fills.map((f) => (
                <div className="item" key={f.id}>
                  <Key id={f.variant} />
                  <div>
                    <div className="t">
                      {fmt(f.quantity, 4)} @ {fmt(f.priceUsd, 4)}
                    </div>
                    <div className="d">
                      fee {fmt(f.feeUsd, 4)} USD · {shortId(f.portfolioRunId)}
                    </div>
                  </div>
                  <span className="ts">{clock(f.createdAt)}</span>
                </div>
              ))
            )}
          </div>
        </Panel>

        <Panel label="Funding settled" hint="The income the whole strategy exists to collect.">
          <div className="feed">
            {funding.length === 0 ? (
              <Empty msg="No funding has settled yet." />
            ) : (
              funding.map((f) => (
                // funding_payments has no variant column — the catalog maps the run
                <div className="item" key={f.id}>
                  <Key id={ownerOf(catalog, f.portfolioRunId)} />
                  <div>
                    <div className="t">
                      {fmt(f.amountUsd, 4, { signed: true })}
                      <span className="unit">USD</span>
                    </div>
                    <div className="d">
                      {f.realizationStatus} · rate {fmt(f.normalizedRate, 6, { signed: true })} ·{" "}
                      {shortId(f.portfolioRunId)}
                    </div>
                  </div>
                  <span className="ts">{clock(Number(f.effectiveAtMs))}</span>
                </div>
              ))
            )}
          </div>
        </Panel>
      </div>
    </Section>
  );
}
