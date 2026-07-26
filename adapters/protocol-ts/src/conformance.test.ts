import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import {
  canonicalExecutionIntent,
  evaluateFixedVector,
  executionIntentHash,
} from "./conformance.js";

const vectorDir =
  process.env.CONFORMANCE_VECTOR_DIR ?? "../../tests/vectors";

async function vector(name: string): Promise<Record<string, unknown>> {
  return JSON.parse(
    await readFile(`${vectorDir}/${name}`, "utf8"),
  ) as Record<string, unknown>;
}

test("matches the shared atomic and execution-intent vectors", async () => {
  for (const name of [
    "fixed-point-baseline-v1.json",
    "fixed-point-boundary-v1.json",
  ]) {
    const input = await vector(name);
    assert.deepEqual(evaluateFixedVector(input), {
      navLamports: input.expectedNavLamports,
      fundingUsdMicros: input.expectedFundingUsdMicros,
      spotEquivalentLamports: input.expectedSpotEquivalentLamports,
      deltaLamports: input.expectedDeltaLamports,
      deltaBps: input.expectedDeltaBps,
      realizedFundingUsdMicros: input.expectedRealizedFundingUsdMicros,
    });
  }

  const intent = await vector("execution-intent-v1.json");
  assert.equal(canonicalExecutionIntent(intent), intent.expectedCanonical);
  assert.equal(executionIntentHash(intent), intent.expectedHash);
});
