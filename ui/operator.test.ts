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
      "/operator/strategies/jitosol_carry/start",
      "operator-secret",
      "console-scoped",
    );

    expect(JSON.parse(request?.body ?? "{}")).toEqual({
      reason: "started from local operator console (strategy: jitosol_carry)",
    });
    expect(request?.headers["x-operator-signature"]).toBe(
      signature("console-scoped", request?.body ?? ""),
    );
    expect(request?.headers["content-length"]).toBe(
      Buffer.byteLength(request?.body ?? "").toString(),
    );
  });

  it("signs live arm and disarm with the generated approval literal", () => {
    const arm = operatorRequest(
      "/operator/strategies/solana_wallet_flow_quant/arm-live",
      "operator-secret",
      "console-arm",
    );

    expect(JSON.parse(arm?.body ?? "{}")).toEqual({
      mode: "live",
      approval: "ARM LIVE TRADING",
      reason: "armed live trading from local operator console (strategy: solana_wallet_flow_quant)",
    });
    expect(arm?.forwardPath).toBe("/v1/strategies/solana_wallet_flow_quant/mode");
    expect(arm?.headers["x-operator-signature"]).toBe(
      signature("console-arm", arm?.body ?? ""),
    );

    const disarm = operatorRequest(
      "/operator/strategies/solana_wallet_flow_quant/disarm-live",
      "operator-secret",
      "console-disarm",
    );
    expect(JSON.parse(disarm?.body ?? "{}")).toEqual({
      mode: "paper",
      reason: "disarmed live trading from local operator console (strategy: solana_wallet_flow_quant)",
    });
    expect(operatorRequest(
      "/v1/strategies/solana_wallet_flow_quant/mode",
      "operator-secret",
      "console-direct-mode",
    )).toBeNull();
  });

  it("rejects malformed strategy control paths", () => {
    for (const url of [
      "/operator/strategies//stop",
      "/operator/strategies/DROP%20TABLE/stop",
      `/operator/strategies/${"a".repeat(65)}/stop`,
    ]) {
      expect(operatorRequest(url, "operator-secret", "k")).toBeNull();
    }
  });

  it("signs a case-sensitive Solana wallet cohort", () => {
    const wallet = "4Nd1mYsfz4S6MWn7p8QK5TyHcV1g2JkL9XaBcDeFgHiJ";
    const request = operatorRequest(
      "/operator/solana-wallets/config",
      "operator-secret",
      "solana-wallet-config",
      JSON.stringify({ wallets: [wallet] }),
    );

    expect(JSON.parse(request?.body ?? "{}")).toEqual({
      reason: "Solana wallet cohort updated from local operator console",
      wallets: [wallet],
    });
    expect(request?.headers["x-operator-signature"]).toBe(
      signature("solana-wallet-config", request?.body ?? ""),
    );
    expect(
      operatorRequest(
        "/operator/solana-wallets/config",
        "operator-secret",
        "invalid-solana-wallet-config",
        '{"wallets":["0x1111111111111111111111111111111111111111"]}',
      ),
    ).toBeNull();
    // A named wallet keeps its name; an unnamed one stays a bare address, so
    // the collector sees the same shape it always did.
    expect(JSON.parse(operatorRequest(
      "/operator/solana-wallets/config",
      "operator-secret",
      "named-solana-wallet-config",
      JSON.stringify({ wallets: [{ wallet, label: "  Gasp (#1 monthly) " }, { wallet: wallet.replace(/J$/, "K") }] }),
    )?.body ?? "{}")).toEqual({
      reason: "Solana wallet cohort updated from local operator console",
      wallets: [{ wallet, label: "Gasp (#1 monthly)" }, wallet.replace(/J$/, "K")],
    });
    for (const wallets of [
      [{ wallet, label: "a".repeat(41) }],          // label beyond the column
      [{ wallet, label: "two\nlines" }],            // labels are single-line
      [{ wallet, nickname: "Gasp" }],               // an unknown field is a typo
      [{ wallet, label: 7 }],                       // a label is text
      [{ label: "no address" }],                    // an entry needs its wallet
      [[wallet]],                                   // not an entry at all
    ]) {
      expect(operatorRequest(
        "/operator/solana-wallets/config",
        "operator-secret",
        "rejected-solana-wallet-config",
        JSON.stringify({ wallets }),
      )).toBeNull();
    }
    // The retired Hyperliquid cohort path has no collector route left.
    expect(
      operatorRequest(
        "/operator/wallets/config",
        "operator-secret",
        "retired-wallet-config",
        '{"wallets":["0x1111111111111111111111111111111111111111"]}',
      ),
    ).toBeNull();
  });
});
