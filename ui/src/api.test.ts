import { describe, expect, it } from "vitest";
import { operatorMessageForTest } from "./api";

describe("operator refusals", () => {
  it("shows the sentence, not the SQLSTATE in front of it", () => {
    expect(operatorMessageForTest(
      { message: "P0001\t\t\t\tparameter maxEntryImpactBps must be between 50 and 600" },
      "tuning failed",
    )).toBe("parameter maxEntryImpactBps must be between 50 and 600");
    expect(operatorMessageForTest({ message: "  plain refusal  " }, "x")).toBe("plain refusal");
    expect(operatorMessageForTest(null, "tuning failed")).toBe("tuning failed");
    expect(operatorMessageForTest({ message: "   " }, "tuning failed")).toBe("tuning failed");
  });
});
