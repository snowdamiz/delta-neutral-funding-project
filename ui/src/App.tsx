import { useEffect, useState } from "react";
import type { Snapshot } from "./api";
import { useSnapshot } from "./api";
import type { Strategy } from "./catalog";
import { narrow, strategyOf } from "./catalog";
import { clock } from "./fmt";
import { health } from "./status";
import { CatalogProvider, Key, Live, StrategyName } from "./ui";
import { Attribution } from "./sections/Attribution";
import { Benchmark } from "./sections/Benchmark";
import { Book } from "./sections/Book";
import { Activity, StatusBanner, SystemHealth } from "./sections/Health";
import { Ledger } from "./sections/Ledger";
import { Markets } from "./sections/Markets";
import { Alerts, Overview, Summary } from "./sections/Overview";
import { Opportunity } from "./sections/Opportunity";
import { Platform } from "./sections/Platform";
import { Risk } from "./sections/Risk";

const TABS = [
  { id: "", label: "Overview", hint: "Money, strategies, alerts" },
  { id: "markets", label: "Markets", hint: "What the collector can see" },
  { id: "system", label: "System", hint: "Health, capabilities, config" },
] as const;

/**
 * One strategy's detail view: the same section components, fed the snapshot
 * narrowed to the rows that strategy owns. Nothing here knows which strategy.
 *
 * Benchmark is the exception and takes the full snapshot — a comparison needs
 * the other side of it, which narrowing has by definition removed.
 */
function Detail({ snap, strategy }: { snap: Snapshot; strategy: Strategy }) {
  const mine = narrow(snap, strategy);
  return (
    <>
      <Benchmark snap={snap} strategy={strategy} />
      <Book snap={mine} />
      <Attribution snap={mine} />
      <Opportunity snap={mine} />
      <Risk snap={mine} />
      <Ledger snap={mine} />
    </>
  );
}

/**
 * `#/markets` · `#/system` · `#/s/<strategy-id>` · anything else is the
 * overview, including the console's old `#<strategy-id>` links.
 */
export function parseRoute(hash: string): { tab: string; strategy: string } {
  const raw = decodeURIComponent(hash.replace(/^#\/?/, ""));
  if (raw.startsWith("s/")) return { tab: "", strategy: raw.slice(2) };
  return { tab: TABS.some((t) => t.id === raw) ? raw : "", strategy: "" };
}

/**
 * Route lives in the hash, so every tab and every strategy is linkable and the
 * browser's Back button does the obvious thing.
 */
function useRoute(): [string, string, (next: string) => void] {
  const [hash, setHash] = useState(() => location.hash);
  useEffect(() => {
    const sync = () => setHash(location.hash);
    addEventListener("hashchange", sync);
    return () => removeEventListener("hashchange", sync);
  }, []);

  const { tab, strategy } = parseRoute(hash);
  return [tab, strategy, (next: string) => { location.hash = `/${next}`; }];
}

export default function App() {
  const snap = useSnapshot();
  const [tab, openId, go] = useRoute();
  // An id that is not in the catalog opens nothing — including a stale link.
  const open = strategyOf(snap.strategies, openId);
  const h = health(snap);

  return (
    <CatalogProvider value={snap.strategies}>
      <header className="topbar">
        <div className="topbar-in">
          <button type="button" className="brand" onClick={() => go("")}>
            Delta&#8209;Neutral <em>Funding</em>
          </button>

          <div className="live">
            <span className={`pill p-${h.tone}`}>
              <span className={`dot${h.tone === "ok" ? "" : " bad"}`} />
              {h.word}
            </span>
            {h.openAlerts > 0 && (
              <span className={`pill p-${h.criticalAlerts > 0 ? "crit" : "warn"}`}>
                {h.openAlerts} open alert{h.openAlerts === 1 ? "" : "s"}
              </span>
            )}
            <Live
              polling={snap.polling}
              at={snap.polledAt}
              reachable={snap.reachable}
              everyMs={snap.intervalMs}
            />
          </div>
        </div>

        <nav className="tabs" aria-label="Sections">
          <div className="tabs-in">
            {TABS.map((t) => (
              <button
                key={t.id}
                type="button"
                className={!open && tab === t.id ? "tab on" : "tab"}
                aria-current={!open && tab === t.id ? "page" : undefined}
                onClick={() => go(t.id)}
              >
                {t.label}
                <span className="thint">{t.hint}</span>
              </button>
            ))}
          </div>
        </nav>
      </header>

      <main className="wrap">
        {open ? (
          <>
            <nav className="switch rise">
              <button type="button" className="back" onClick={() => go("")}>← All strategies</button>
              <div className="pills">
                {snap.strategies.map((s) => (
                  <button
                    key={s.id}
                    type="button"
                    className={s.id === open.id ? "spill on" : "spill"}
                    onClick={() => go(`s/${s.id}`)}
                  >
                    <Key id={s.id} />
                    <StrategyName id={s.id} />
                  </button>
                ))}
              </div>
            </nav>

            <div className="lede rise">
              <h1><StrategyName id={open.id} /></h1>
              <p>
                <span className="micro">{open.family}</span>
                {open.legs.join("  ·  ")}
              </p>
            </div>

            <Detail snap={snap} strategy={open} />
          </>
        ) : tab === "markets" ? (
          <Markets snap={snap} />
        ) : tab === "system" ? (
          <>
            <Activity snap={snap} />
            <SystemHealth snap={snap} />
            <Platform snap={snap} />
          </>
        ) : (
          <>
            <StatusBanner snap={snap} />
            <Summary snap={snap} />
            <Alerts snap={snap} />
            <Overview
              snap={snap}
              onOpen={(id) => go(`s/${id}`)}
              onManageWallets={() => go("markets")}
            />
          </>
        )}

        <footer>
          <span>Paper mode · no signer route · bounded local controls only</span>
          <span>{snap.polledAt ? `last poll ${clock(snap.polledAt)}` : "—"}</span>
        </footer>
      </main>
    </CatalogProvider>
  );
}
