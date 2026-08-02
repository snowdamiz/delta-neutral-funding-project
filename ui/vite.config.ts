import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
import { operatorRequest } from "./operator";
import { approvedDatabaseReset } from "./reset";

// The collector emits no CORS headers, so the console must be same-origin with
// its API. The bounded local controls are signed here, so the browser never
// receives the operator secret.
const COLLECTOR = process.env.COLLECTOR ?? "http://127.0.0.1:8080";
const PROJECT = fileURLToPath(new URL("..", import.meta.url));
const DEV_SCRIPT = fileURLToPath(new URL("../dev.sh", import.meta.url));

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, "..", "");
  const operatorSecret =
    process.env.OPERATOR_HMAC_SECRET ??
    env.OPERATOR_HMAC_SECRET ??
    "local-operator-only-change-me";
  let databaseResetting = false;

  return {
    plugins: [
      react(),
      {
        name: "local-operator-proxy",
        configureServer(server) {
          server.middlewares.use("/operator/reset-database", (request, response) => {
            if (request.method !== "POST") {
              response.statusCode = 405;
              response.end();
              return;
            }
            const chunks: Buffer[] = [];
            let size = 0;
            request.on("data", (chunk) => {
              size += chunk.length;
              if (size <= 1024) chunks.push(Buffer.from(chunk));
            });
            request.on("end", () => {
              response.setHeader("content-type", "application/json");
              if (size > 1024 || !approvedDatabaseReset(Buffer.concat(chunks).toString())) {
                response.statusCode = 400;
                response.end('{"error":"reset_approval_required"}');
                return;
              }
              if (databaseResetting) {
                response.statusCode = 409;
                response.end('{"error":"database_reset_in_progress"}');
                return;
              }
              databaseResetting = true;
              execFile(
                DEV_SCRIPT,
                ["reset-db", "--approve-paper-reset"],
                { cwd: PROJECT, timeout: 180_000, maxBuffer: 262_144 },
                (error) => {
                  databaseResetting = false;
                  response.statusCode = error ? 500 : 200;
                  response.end(error
                    ? '{"error":"database_reset_failed"}'
                    : '{"status":"restarted"}');
                },
              );
            });
          });
          for (const [path, upstreamPath] of [
            ["/operator/solana-wallets/config", "/v1/solana-wallet-flow/config"],
            ["/operator/solana-wallets/tuning", "/v1/solana-wallet-flow/tuning"],
          ] as const) {
            server.middlewares.use(path, (request, response) => {
              if (request.method !== "POST") {
                response.statusCode = 405;
                response.end();
                return;
              }
              const chunks: Buffer[] = [];
              let size = 0;
              request.on("data", (chunk) => {
                size += chunk.length;
                if (size <= 8192) chunks.push(Buffer.from(chunk));
              });
              request.on("end", async () => {
                if (size > 8192) {
                  response.statusCode = 413;
                  response.end('{"error":"request_too_large"}');
                  return;
                }
                const signed = operatorRequest(
                  path,
                  operatorSecret,
                  `console-${Date.now()}-${randomUUID()}`,
                  Buffer.concat(chunks).toString(),
                );
                if (!signed) {
                  response.statusCode = 400;
                  response.end('{"error":"invalid_wallet_config"}');
                  return;
                }
                try {
                  const upstream = await fetch(`${COLLECTOR}${upstreamPath}`, {
                    method: "POST",
                    headers: signed.headers,
                    body: signed.body,
                  });
                  response.statusCode = upstream.status;
                  response.setHeader(
                    "content-type",
                    upstream.headers.get("content-type") ?? "application/json",
                  );
                  response.end(await upstream.text());
                } catch {
                  response.statusCode = 502;
                  response.end('{"error":"collector_unreachable"}');
                }
              });
            });
          }
        },
      },
    ],
    server: {
      host: "127.0.0.1",
      port: 5173,
      proxy: {
        "/v1": { target: COLLECTOR, changeOrigin: false },
        "/operator": {
          target: COLLECTOR,
          changeOrigin: false,
          rewrite: (path) => path.replace(/^\/operator/, "/v1"),
          configure: (proxy) => {
            proxy.on("proxyReq", (proxyReq, request) => {
              const signed = operatorRequest(
                request.url,
                operatorSecret,
                `console-${Date.now()}-${randomUUID()}`,
              );
              if (!signed) return;
              if (signed.forwardPath !== undefined) proxyReq.path = signed.forwardPath;
              Object.entries(signed.headers).forEach(([name, value]) =>
                proxyReq.setHeader(name, value),
              );
              proxyReq.write(signed.body);
            });
          },
        },
      },
    },
    build: { outDir: "dist", sourcemap: true },
  };
});
