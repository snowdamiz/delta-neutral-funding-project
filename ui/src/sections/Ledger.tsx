import type { Snapshot } from "../api";
import { clock, fmt, shortId } from "../fmt";
import { Chip, Empty, Key, Panel, Section, type Tone } from "../ui";

const ORDER_TONE: Record<string, Tone> = {
  FILLED: "ok",
  PARTIAL: "warn",
  REJECTED: "crit",
  UNKNOWN: "crit",
};

export function Ledger({ snap }: { snap: Snapshot }) {
  const { orders, fills, funding } = snap;

  return (
    <Section n="06" title="Ledger" note="paper execution record">
      <div className="cols-3">
        <Panel label="Orders">
          <div className="feed">
            {orders.length === 0 ? (
              <Empty msg="no orders — nothing has been submitted" />
            ) : (
              orders.map((o) => (
                <div className="item" key={o.id}>
                  <Chip tone={ORDER_TONE[o.status] ?? "mute"}>{o.status}</Chip>
                  <div>
                    <div className="t">
                      <Key variant={o.variant} />
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

        <Panel label="Fills">
          <div className="feed">
            {fills.length === 0 ? (
              <Empty msg="no fills recorded" />
            ) : (
              fills.map((f) => (
                <div className="item" key={f.id}>
                  <Key variant={f.variant} />
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

        <Panel label="Funding">
          <div className="feed">
            {funding.length === 0 ? (
              <Empty msg="no funding settlements yet" />
            ) : (
              funding.map((f) => (
                // funding_payments has no variant column — derive it from the run id
                <div className="item" key={f.id}>
                  <Key
                    variant={
                      /jitosol/.test(f.portfolioRunId) ? "jitosol_carry" : "sol_control"
                    }
                  />
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
