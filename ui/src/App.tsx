import { useEffect, useState } from "react";
import type { Snapshot } from "./api";
import { useSnapshot } from "./api";
import type { Strategy } from "./catalog";
import { familiesOf, narrow, netOf, strategyOf } from "./catalog";
import { clock, fmt, toNumber } from "./fmt";
import { health } from "./status";
import { CatalogProvider, Key, StrategyName, VerboseProvider } from "./ui";
import { Attribution } from "./sections/Attribution";
import { Benchmark } from "./sections/Benchmark";
import { Book } from "./sections/Book";
import { Control, StatusBanner, SystemHealth } from "./sections/Health";
import { Ledger } from "./sections/Ledger";
import { Markets } from "./sections/Markets";
import { Alerts, Overview, Summary } from "./sections/Overview";
import { Opportunity } from "./sections/Opportunity";
import { Platform } from "./sections/Platform";
import { Risk } from "./sections/Risk";
import { WalletFlow } from "./sections/WalletFlow";

const PAGES = [
  { id: "markets", label: "Markets" },
  { id: "system", label: "System" },
] as const;

/**
 * The four questions a strategy answers. Six sections stacked into one
 * unbroken scroll had no way to jump; as sub-tabs each one is a destination.
 */
const SUBS = [
  { id: "", label: "Book" },
  { id: "pnl", label: "P&L" },
  { id: "evals", label: "Evals" },
  { id: "risk", label: "Risk" },
] as const;

/**
 * One strategy's detail: the same section components, fed the snapshot narrowed
 * to the rows that strategy owns. Nothing here knows which strategy.
 *
 * Benchmark is the exception and takes the full snapshot — a comparison needs
 * the other side of it, which narrowing has by definition removed.
 */
function Detail({ snap, strategy, sub }: { snap: Snapshot; strategy: Strategy; sub: string }) {
  // The wallet-flow strategy has its own broker, ledger, and live switch, so
  // it carries the one bespoke view; every other strategy renders generically.
  if (strategy.id === "solana_wallet_flow_quant") {
    return <WalletFlow snap={snap} strategy={strategy.id} />;
  }
  const mine = narrow(snap, strategy);
  if (sub === "pnl") {
    return (
      <>
        <Benchmark snap={snap} strategy={strategy} />
        <Attribution snap={mine} />
      </>
    );
  }
  if (sub === "evals") return <Opportunity snap={mine} />;
  if (sub === "risk") return <Risk snap={mine} />;
  return (
    <>
      <Book snap={mine} />
      <Ledger snap={mine} />
    </>
  );
}

/**
 * `#/markets` · `#/system` · `#/s/<strategy-id>[/<sub-tab>]` · anything else is
 * the overview, including the console's old `#<strategy-id>` links.
 */
export function parseRoute(hash: string): { tab: string; strategy: string; sub: string } {
  const raw = decodeURIComponent(hash.replace(/^#\/?/, ""));
  if (raw.startsWith("s/")) {
    const [strategy = "", sub = ""] = raw.slice(2).split("/");
    return { tab: "", strategy, sub: SUBS.some((s) => s.id === sub) ? sub : "" };
  }
  return { tab: PAGES.some((p) => p.id === raw) ? raw : "", strategy: "", sub: "" };
}

/**
 * Route lives in the hash, so every page, strategy, and sub-tab is linkable and
 * the browser's Back button does the obvious thing.
 */
function useRoute(): [string, string, string, (next: string) => void] {
  const [hash, setHash] = useState(() => location.hash);
  useEffect(() => {
    const sync = () => setHash(location.hash);
    addEventListener("hashchange", sync);
    return () => removeEventListener("hashchange", sync);
  }, []);

  const { tab, strategy, sub } = parseRoute(hash);
  return [tab, strategy, sub, (next: string) => { location.hash = `/${next}`; }];
}

/** A strategy's recorded net, or a dash when it has never recorded one. */
function Net({ snap, strategy }: { snap: Snapshot; strategy: Strategy }) {
  if (!snap.pnl.some((p) => p.variant === strategy.id)) {
    return <span className="rnet">—</span>;
  }
  const net = netOf(snap, strategy);
  const n = toNumber(net);
  return (
    <span className="rnet" style={{ color: `var(--${n > 0 ? "ok" : n < 0 ? "crit" : "ink2"})` }}>
      {fmt(net, 2, { signed: true })}
    </span>
  );
}

export default function App() {
  const snap = useSnapshot();
  const [tab, openId, sub, go] = useRoute();
  // An id that is not in the catalog opens nothing — including a stale link.
  const open = strategyOf(snap.strategies, openId);
  const h = health(snap);
  // Survives a reload: an operator who wants the prose wants it every session.
  const [verbose, setVerbose] = useState(() => localStorage.getItem("explain") === "1");
  const at = (id: string) => !open && tab === id;

  return (
    <CatalogProvider value={snap.strategies}>
      <VerboseProvider value={verbose}>
        <div className="shell">
          <aside className="rail">
            <div className="rail-top">
              <button type="button" className="brand" onClick={() => go("")}>
                Delta&#8209;Neutral <em>Funding</em>
              </button>
              {/* Nothing here in the normal case. A poll clock and a "waiting"
                  badge that is true almost always are noise beside the data
                  they describe; the panels carry their own arrival state. Only
                  a state worth acting on still shows. */}
              {h.tone !== "ok" && (
                <span className={`pill p-${h.tone}`}>
                  <span className="dot bad" />
                  {h.word}
                </span>
              )}
              {h.openAlerts > 0 && (
                <span className={`pill p-${h.criticalAlerts > 0 ? "crit" : "warn"}`}>
                  {h.openAlerts} alert{h.openAlerts === 1 ? "" : "s"}
                </span>
              )}
            </div>

            {/* The strategies are the navigation. They used to be reachable only
                by scrolling the overview, with a second pill bar appearing once
                you were inside one. */}
            <nav className="rail-nav" aria-label="Strategies">
              <button
                type="button"
                className={at("") ? "rlink all on" : "rlink all"}
                aria-current={at("") ? "page" : undefined}
                onClick={() => go("")}
              >
                <span className="rname">All strategies</span>
              </button>

              {familiesOf(snap.strategies).map((family) => (
                <div className="rgroup" key={family}>
                  <span className="lbl">{family}</span>
                  {snap.strategies
                    .filter((s) => s.family === family)
                    .map((s) => (
                      <button
                        key={s.id}
                        type="button"
                        className={open?.id === s.id ? "rlink on" : "rlink"}
                        aria-current={open?.id === s.id ? "page" : undefined}
                        onClick={() => go(`s/${s.id}`)}
                      >
                        <Key id={s.id} />
                        <span className="rname"><StrategyName id={s.id} /></span>
                        <Net snap={snap} strategy={s} />
                      </button>
                    ))}
                </div>
              ))}
            </nav>

            <div className="rail-foot">
              {PAGES.map((p) => (
                <button
                  key={p.id}
                  type="button"
                  className={at(p.id) ? "rlink on" : "rlink"}
                  aria-current={at(p.id) ? "page" : undefined}
                  onClick={() => go(p.id)}
                >
                  <span className="rname">{p.label}</span>
                </button>
              ))}
              <div className="rail-meta">
                <span className="pill p-mute">paper</span>
                <span>{snap.polledAt ? clock(snap.polledAt) : "—"}</span>
                <button
                  type="button"
                  className="explain"
                  aria-pressed={verbose}
                  title={verbose ? "Hide explanations" : "Explain every panel"}
                  onClick={() => {
                    setVerbose(!verbose);
                    localStorage.setItem("explain", verbose ? "0" : "1");
                  }}
                >
                  ?
                </button>
              </div>
            </div>
          </aside>

          <main className="pane">
            {open ? (
              <>
                <div className="head rise">
                  <div>
                    <h1><StrategyName id={open.id} /></h1>
                    <p className="micro">{open.legs.join("  ·  ") || open.family}</p>
                  </div>
                  {h.controllable
                    && open.runState !== "unregistered"
                    && open.controlScope === "strategy" && (
                    <Control paused={!open.enabled} strategy={open.id} />
                  )}
                </div>

                {open.id !== "solana_wallet_flow_quant" && (
                <nav className="subs rise" aria-label="Strategy views">
                  {SUBS.map((s) => (
                    <button
                      key={s.id}
                      type="button"
                      className={sub === s.id ? "sub on" : "sub"}
                      aria-current={sub === s.id ? "page" : undefined}
                      onClick={() => go(`s/${open.id}${s.id ? `/${s.id}` : ""}`)}
                    >
                      {s.label}
                    </button>
                  ))}
                </nav>
                )}

                <Detail snap={snap} strategy={open} sub={sub} />
              </>
            ) : tab === "markets" ? (
              <Markets snap={snap} />
            ) : tab === "system" ? (
              <>
                <SystemHealth snap={snap} />
                <Platform snap={snap} />
              </>
            ) : (
              <>
                <StatusBanner snap={snap} />
                <Summary snap={snap} />
                <Alerts snap={snap} />
                <Overview snap={snap} onOpen={(id) => go(`s/${id}`)} />
              </>
            )}
          </main>
        </div>
      </VerboseProvider>
    </CatalogProvider>
  );
}
