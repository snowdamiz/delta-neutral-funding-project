import type { Snapshot } from "../api";
import { Empty, Panel, Section, type Tone } from "../ui";

const CAP_TONE: Record<string, Tone> = {
  implemented: "ok",
  project_local: "mute",
  deferred: "warn",
};
const GLYPH: Record<Tone, string> = { ok: "●", warn: "▲", crit: "■", mute: "○" };
const CAP_WORD: Record<string, string> = {
  implemented: "in the platform",
  project_local: "built here",
  deferred: "not built yet",
};

export function Platform({ snap }: { snap: Snapshot }) {
  const { capabilities, buildManifestId, config } = snap;

  const counts = capabilities.reduce<Record<string, number>>((acc, c) => {
    acc[c.status] = (acc[c.status] ?? 0) + 1;
    return acc;
  }, {});

  return (
    <Section
      title="Capabilities and configuration"
      note="What this build can do, and the exact settings it is pinned to. Hover a capability for the evidence behind its claim."
    >
      <Panel
        label="Capability matrix"
        hint={Object.entries(counts).map(([k, v]) => `${v} ${CAP_WORD[k] ?? k}`).join(" · ")}
        aside={<span className="micro">{buildManifestId}</span>}
      >
        {capabilities.length === 0 ? (
          <Empty msg="Capability matrix unavailable." />
        ) : (
          <div className="caps">
            {capabilities.map((c) => (
              <span className="cap-chip" data-s={c.status} key={c.id} title={c.evidence}>
                <span className="g" aria-hidden="true">{GLYPH[CAP_TONE[c.status] ?? "mute"]}</span>
                {c.id.replaceAll("_", " ")}
              </span>
            ))}
          </div>
        )}
      </Panel>

      <div className="panel">
        <details className="cfg">
          <summary>
            <span>Pinned runtime configuration ({config ? Object.keys(config).length : 0} settings)</span>
          </summary>
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
