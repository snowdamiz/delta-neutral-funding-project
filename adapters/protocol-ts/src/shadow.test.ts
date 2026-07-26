import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { buildShadowAction } from "./shadow.js";

const vectorDir = process.env.CONFORMANCE_VECTOR_DIR ?? "../../tests/vectors";

async function vector(name: string): Promise<Record<string, unknown>> {
  return JSON.parse(
    await readFile(`${vectorDir}/${name}`, "utf8"),
  ) as Record<string, unknown>;
}

test("builds bounded simulation-only Jupiter and perp actions", async () => {
  for (const [intentName, simulationName, expectedMarket] of [
    ["shadow-intent-v1.json", "shadow-simulation-perp-v1.json", "SOL-PERP"],
    [
      "shadow-intent-jitosol-v1.json",
      "shadow-simulation-jitosol-v1.json",
      "JUPITER:JITOSOL-USDC",
    ],
  ] as const) {
    const intent = await vector(intentName);
    const action = buildShadowAction(intent, await vector(simulationName));
    assert.equal(action.market, expectedMarket);
    assert.equal(action.simulateOnly, true);
    assert.equal(action.submit, false);
    assert.equal(action.simulatedQuantityAtoms, intent.maxQuantityAtoms);
    assert.match(action.intentHash, /^[0-9a-f]{64}$/);
    assert.match(action.messageHash, /^[0-9a-f]{64}$/);
    assert.ok(action.accountDeltas.length > 0);
  }

  const intent = await vector("shadow-intent-v1.json");
  const expanded = await vector("shadow-simulation-perp-v1.json");
  expanded.quantityAtoms = (
    BigInt(intent.maxQuantityAtoms as string) + 1n
  ).toString();
  assert.throws(
    () => buildShadowAction(intent, expanded),
    /simulation exceeds execution intent/,
  );
});
