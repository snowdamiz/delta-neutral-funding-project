import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { buildSyntheticEvent } from "./contracts.js";
import { postEvent, signBody } from "./transport.js";

test("authenticates and posts the canonical body unchanged", async () => {
  const event = buildSyntheticEvent(9n, 1_785_024_000_000n, "transport-test");
  const expectedBody = JSON.stringify(event);
  let receivedBody = "";
  let receivedSignature = "";
  const server = createServer((request, response) => {
    request.setEncoding("utf8");
    request.on("data", (chunk: string) => {
      receivedBody += chunk;
    });
    request.on("end", () => {
      receivedSignature = String(request.headers["x-adapter-signature"] ?? "");
      response.writeHead(202, { "content-type": "application/json" });
      response.end('{"status":"accepted"}');
    });
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert(address && typeof address !== "string");

  try {
    const response = await postEvent(
      `http://127.0.0.1:${address.port}/v1/events`,
      "test-secret",
      event,
      1000,
    );
    assert.equal(response.status, 202);
    assert.equal(receivedBody, expectedBody);
    assert.equal(receivedSignature, signBody("test-secret", expectedBody));
  } finally {
    server.close();
  }
});
