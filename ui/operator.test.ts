import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { approvedDatabaseReset, operatorRequest } from "./operator";

const signature = (key: string, body: string) =>
  createHmac("sha256", "operator-secret").update(`${key}\n${body}`).digest("hex");

describe("operator proxy request", () => {
  it("requires the exact destructive reset approval", () => {
    expect(approvedDatabaseReset('{"approval":"WIPE PAPER DATABASE"}')).toBe(true);
    expect(approvedDatabaseReset('{"approval":"wipe paper database"}')).toBe(false);
    expect(approvedDatabaseReset('{"approval":"WIPE PAPER DATABASE","extra":true}')).toBe(false);
    expect(approvedDatabaseReset("not json")).toBe(false);
  });

  it("only signs the bounded browser controls", () => {
    const request = operatorRequest("/operator/pause-all", "operator-secret", "console-test");

    expect(request).not.toBeNull();
    expect(request?.headers["x-operator-signature"]).toBe(
      signature("console-test", request?.body ?? ""),
    );
    expect(operatorRequest("/operator/emergency-flatten", "operator-secret", "bad")).toBeNull();
    expect(operatorRequest("/operator/paper/reset", "operator-secret", "bad")).toBeNull();
  });

  it("carries the strategy scope into the signed reason", () => {
    const request = operatorRequest(
      "/operator/resume?strategy=jitosol_carry",
      "operator-secret",
      "console-scoped",
    );

    expect(JSON.parse(request?.body ?? "{}")).toEqual({
      reason: "started from local operator console (strategy: jitosol_carry)",
      strategy: "jitosol_carry",
    });
    expect(request?.headers["x-operator-signature"]).toBe(
      signature("console-scoped", request?.body ?? ""),
    );
    expect(request?.headers["content-length"]).toBe(
      Buffer.byteLength(request?.body ?? "").toString(),
    );
  });

  it("drops a scope the collector would not recognise", () => {
    for (const url of [
      "/operator/pause-all",
      "/operator/pause-all?strategy=",
      "/operator/pause-all?strategy=DROP%20TABLE",
      `/operator/pause-all?strategy=${"a".repeat(65)}`,
    ]) {
      expect(JSON.parse(operatorRequest(url, "operator-secret", "k")?.body ?? "{}")).toEqual({
        reason: "stopped from local operator console",
      });
    }
  });

  it("signs a validated canonical wallet cohort", () => {
    const address = `0x${"A".repeat(40)}`;
    const request = operatorRequest(
      "/operator/wallets/config",
      "operator-secret",
      "wallet-config",
      JSON.stringify({ wallets: [address] }),
    );

    expect(JSON.parse(request?.body ?? "{}")).toEqual({
      reason: "wallet cohort updated from local operator console",
      wallets: [address.toLowerCase()],
    });
    expect(request?.headers["x-operator-signature"]).toBe(
      signature("wallet-config", request?.body ?? ""),
    );
    expect(
      operatorRequest(
        "/operator/wallets/config",
        "operator-secret",
        "invalid-wallet-config",
        '{"wallets":["not-a-wallet"]}',
      ),
    ).toBeNull();
  });
});
