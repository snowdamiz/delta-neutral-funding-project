import { describe, it, expect } from "vitest";
import { toDecimalString, round, fmt, age, diff, latest, ms, negate, sum } from "./fmt";

describe("timestamps", () => {
  it("reads both shapes the read API emits", () => {
    expect(ms("1753900000000")).toBe(1753900000000); // observedAtMs
    expect(ms(1753900000000)).toBe(1753900000000);
    expect(ms("2026-07-31T09:00:00.000Z")).toBe(Date.parse("2026-07-31T09:00:00.000Z"));
  });

  it("returns 0 rather than 1970 for anything unreadable", () => {
    expect(ms(null)).toBe(0);
    expect(ms(undefined)).toBe(0);
    expect(ms("")).toBe(0);
    expect(ms("not a date")).toBe(0);
  });

  it("takes the newest of a set, mixed shapes included", () => {
    expect(latest([{ t: "1000" }, { t: "2026-01-01T00:00:00Z" }, { t: null }], (r) => r.t))
      .toBe(Date.parse("2026-01-01T00:00:00Z"));
    expect(latest([], (r: { t: string }) => r.t)).toBe(0);
  });
});

describe("fixed-point conversion", () => {
  it("is exact, including atoms shorter than the scale", () => {
    expect(toDecimalString({ atoms: "500000000", scale: 6 })).toBe("500.000000");
    expect(toDecimalString({ atoms: "5", scale: 6 })).toBe("0.000005");
    expect(toDecimalString({ atoms: "0", scale: 9 })).toBe("0.000000000");
    expect(toDecimalString({ atoms: "-1234567", scale: 6 })).toBe("-1.234567");
    expect(toDecimalString({ atoms: "42", scale: 0 })).toBe("42");
  });

  it("survives values past Number.MAX_SAFE_INTEGER", () => {
    // the reason this module uses BigInt at all: perp depth arrives in lamports
    expect(toDecimalString({ atoms: "23014750000000", scale: 9 })).toBe("23014.750000000");
    expect(round({ atoms: "9007199254740993", scale: 0 }, 0)).toBe("9007199254740993");
  });
});

describe("rounding", () => {
  it("goes half away from zero in both directions", () => {
    expect(round({ atoms: "1234500", scale: 6 }, 2)).toBe("1.23");
    expect(round({ atoms: "1235000", scale: 6 }, 2)).toBe("1.24");
    expect(round({ atoms: "-1235000", scale: 6 }, 2)).toBe("-1.24");
  });

  it("carries into the integer part", () => {
    expect(round({ atoms: "999999", scale: 6 }, 2)).toBe("1.00");
  });

  it("does not lose or invent digits when widening the scale", () => {
    expect(round({ atoms: "1", scale: 6 }, 2)).toBe("0.00");
    expect(round({ atoms: "15", scale: 2 }, 6)).toBe("0.150000");
  });
});

describe("exact arithmetic", () => {
  it("sums across scales without touching a float", () => {
    expect(toDecimalString(sum({ atoms: "1500000", scale: 6 }, { atoms: "25", scale: 2 })))
      .toBe("1.750000");
    expect(toDecimalString(sum({ atoms: "9007199254740993", scale: 0 }, { atoms: "1", scale: 0 })))
      .toBe("9007199254740994");
  });

  it("treats absent values as absent, not as zero-scale noise", () => {
    expect(toDecimalString(sum(null, { atoms: "1", scale: 9 }))).toBe("0.000000001");
    expect(toDecimalString(sum())).toBe("0");
  });

  it("subtracts exactly in both directions", () => {
    expect(toDecimalString(diff({ atoms: "1750000", scale: 6 }, { atoms: "1000000", scale: 6 })))
      .toBe("0.750000");
    expect(toDecimalString(diff({ atoms: "800000", scale: 6 }, { atoms: "900000", scale: 6 })))
      .toBe("-0.100000");
    expect(toDecimalString(negate({ atoms: "-5", scale: 6 }))).toBe("0.000005");
  });
});

describe("display", () => {
  it("groups thousands and carries an explicit sign when asked", () => {
    expect(fmt({ atoms: "1234567890123", scale: 6 }, 2)).toBe("1,234,567.89");
    expect(fmt({ atoms: "500000000", scale: 6 }, 2, { signed: true })).toBe("+500.00");
    expect(fmt({ atoms: "-500000000", scale: 6 }, 2, { signed: true })).toBe("-500.00");
  });

  it("renders absent values as an em dash rather than NaN", () => {
    expect(fmt(null)).toBe("—");
    expect(fmt(undefined, 2)).toBe("—");
  });

  it("formats ages compactly", () => {
    expect(age("30381743")).toBe("8h 26m");
    expect(age("45000")).toBe("45s");
    expect(age(undefined)).toBe("—");
  });
});
