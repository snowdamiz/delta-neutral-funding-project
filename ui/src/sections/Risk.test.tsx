import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { RiskEvent } from "../api";
import { EventFeed } from "./Risk";

const event = (over: Partial<RiskEvent> & { id: string }): RiskEvent => ({
  code: over.id,
  message: "",
  severity: "warning",
  createdAt: "2026-07-30T12:00:00Z",
  resolvedAt: null,
  actionTaken: null,
  portfolioRunId: null,
  ...over,
});

const order = (events: RiskEvent[]): string[] =>
  [...renderToStaticMarkup(<EventFeed events={events} empty="none" />)
    .matchAll(/class="t">([a-z0-9 ]+)</g)].map((m) => m[1]!);

describe("alert feed", () => {
  // The read API returns newest-first, which buries an hour-old critical under
  // a minute-old warning — the inversion of what someone triaging needs.
  it("puts unresolved criticals above newer warnings", () => {
    expect(order([
      event({ id: "recent_warning", createdAt: "2026-07-30T17:00:00Z" }),
      event({ id: "older_critical", severity: "critical", createdAt: "2026-07-30T16:00:00Z" }),
    ])).toEqual(["older critical", "recent warning"]);
  });

  it("sinks resolved events below everything still open", () => {
    expect(order([
      event({ id: "resolved_critical", severity: "critical", resolvedAt: "2026-07-30T18:00:00Z" }),
      event({ id: "open_warning" }),
    ])).toEqual(["open warning", "resolved critical"]);
  });

  it("breaks ties on recency and leaves the source list untouched", () => {
    const events = [
      event({ id: "old", createdAt: "2026-07-30T10:00:00Z" }),
      event({ id: "new", createdAt: "2026-07-30T18:00:00Z" }),
    ];
    expect(order(events)).toEqual(["new", "old"]);
    expect(events.map((e) => e.id)).toEqual(["old", "new"]);
  });
});
