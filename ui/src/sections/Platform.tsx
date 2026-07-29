import type { Snapshot } from "../api";
import { Empty, Panel, Section, type Tone } from "../ui";

const CAP_TONE: Record<string, Tone> = {
  implemented: "ok",
  project_local: "mute",
  deferred: "warn",
};
const GLYPH: Record<Tone, string> = { ok: "●", warn: "▲", crit: "■", mute: "○" };

export function Platform({ snap }: { snap: Snapshot }) {
  const { capabilities, buildManifestId, config } = snap;

  const counts = capabilities.reduce<Record<string, number>>((acc, c) => {
    acc[c.status] = (acc[c.status] ?? 0) + 1;
    return acc;
  }, {});
  const note = Object.entries(counts)
    .map(([k, v]) => `${v} ${k.replace("_", " ")}`)
    .join(" · ");

  return (
    <Section n="07" title="Platform" note={note}>
      <div style={{ marginBottom: "1.5rem" }}>
        <Panel label="Capability matrix" aside={<span className="micro">{buildManifestId}</span>}>
          {capabilities.length === 0 ? (
            <Empty msg="capability matrix unavailable" />
          ) : (
            <div className="caps">
              {capabilities.map((c) => (
                <span className="cap-chip" data-s={c.status} key={c.id} title={c.evidence}>
                  <span className="g" aria-hidden="true">{GLYPH[CAP_TONE[c.status] ?? "mute"]}</span>
                  {c.id}
                </span>
              ))}
            </div>
          )}
        </Panel>
      </div>

      <div className="panel">
        <details className="cfg">
          <summary><span>Pinned runtime configuration</span></summary>
          <div className="cfg-grid">
            {config &&
              Object.keys(config)
                .sort()
                .map((k) => (
                  <div key={k}>
                    <dt>{k}</dt>
                    <dd>{String(config[k])}</dd>
                  </div>
                ))}
          </div>
        </details>
      </div>
    </Section>
  );
}
