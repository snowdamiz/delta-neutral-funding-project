import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { DatabaseReset } from "./Health";

describe("paper database reset", () => {
  it("starts locked behind an explicit destructive approval", () => {
    const html = renderToStaticMarkup(<DatabaseReset />);

    expect(html).toContain("WIPE PAPER DATABASE");
    expect(html).toContain("Wipe database and restart");
    expect(html).toContain("disabled");
  });
});
