import { randomUUID } from "node:crypto";
import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
import { operatorRequest } from "./operator";

// The collector emits no CORS headers, so the console must be same-origin with
// its API. The bounded local controls are signed here, so the browser never
// receives the operator secret.
const COLLECTOR = process.env.COLLECTOR ?? "http://127.0.0.1:8080";

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, "..", "");
  const operatorSecret =
    process.env.OPERATOR_HMAC_SECRET ??
    env.OPERATOR_HMAC_SECRET ??
    "local-operator-only-change-me";

  return {
    plugins: [
      react(),
      {
        name: "wallet-config-proxy",
        configureServer(server) {
          server.middlewares.use("/operator/wallets/config", (request, response) => {
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
                "/operator/wallets/config",
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
                const upstream = await fetch(`${COLLECTOR}/v1/wallets/config`, {
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
