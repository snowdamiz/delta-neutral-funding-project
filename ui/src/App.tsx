import { useSnapshot } from "./api";
import { clock } from "./fmt";
import { Signal } from "./sections/Signal";
import { Thesis } from "./sections/Thesis";
import { Book } from "./sections/Book";
import { Attribution } from "./sections/Attribution";
import { Risk } from "./sections/Risk";
import { Opportunity } from "./sections/Opportunity";
import { Ledger } from "./sections/Ledger";
import { Platform } from "./sections/Platform";

const short = (s: string | undefined) => (s ? s.slice(0, 12) : "—");

export default function App() {
  const snap = useSnapshot();

  return (
    <div className="wrap">
      <header className="rise">
        <div>
          <h1>
            Delta&#8209;Neutral <em>Funding</em>
          </h1>
          <p className="sub">
            Long spot, short SOL&#8209;PERP. Two variants under simultaneous paper execution — does
            JitoSOL&apos;s staking yield actually survive the carry?
          </p>
        </div>
        <dl className="meta">
          <dt>feed</dt>
          <dd className="live">
            <span className={`dot${snap.reachable ? "" : " bad"}`} />
            <span>{snap.polledAt === 0 ? "connecting" : snap.reachable ? "streaming" : "offline"}</span>
          </dd>
          <dt>code</dt>
          <dd>{short(snap.build?.codeCommit)}</dd>
          <dt>mesh</dt>
          <dd>{short(snap.build?.meshCommit)}</dd>
          <dt>config</dt>
          <dd>{short(snap.build?.configHash)}</dd>
          <dt>schema</dt>
          <dd>{snap.build?.schemaVersion ?? "—"}</dd>
        </dl>
      </header>

      <Signal snap={snap} />
      <Thesis snap={snap} />
      <Book snap={snap} />
      <Attribution snap={snap} />
      <Risk snap={snap} />
      <Opportunity snap={snap} />
      <Ledger snap={snap} />
      <Platform snap={snap} />

      <footer>
        <span>Paper mode · read-only console · no signer route</span>
        <span>{snap.polledAt ? `last poll ${clock(snap.polledAt)}` : "—"}</span>
      </footer>
    </div>
  );
}
