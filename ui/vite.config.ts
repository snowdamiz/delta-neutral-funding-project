import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The collector emits no CORS headers, so the console must be same-origin with
// the read API. Vite's dev proxy handles that; `serve.py` does the same for a
// production build. Only GET traffic ever leaves this page — every mutating
// collector route is a POST and stays with `bin/collector`, which holds the
// operator HMAC secret.
const COLLECTOR = process.env.COLLECTOR ?? "http://127.0.0.1:8080";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "127.0.0.1",
    port: 5173,
    proxy: { "/v1": { target: COLLECTOR, changeOrigin: false } },
  },
  build: { outDir: "dist", sourcemap: true },
});
