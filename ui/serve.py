#!/usr/bin/env python3
"""Serve the built console (`npm run build`) with the collector proxied same-origin.

`npm run dev` already does this via Vite's dev proxy; this is the equivalent for
a production build, with no Node runtime required.

The proxy is deliberately GET-only and its upstream is fixed at startup. Every
mutating collector route (pause, resume, exit, emergency-flatten, paper reset)
is a POST and is therefore unreachable from the browser by construction; those
stay with `bin/collector`, which holds the operator HMAC secret. Nothing here
ever sees a secret.

    python3 ui/serve.py                  # http://127.0.0.1:8081
    PORT=9000 COLLECTOR=http://127.0.0.1:8080 python3 ui/serve.py
"""

import http.server
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DIST = Path(__file__).resolve().parent / "dist"
COLLECTOR = os.environ.get("COLLECTOR", "http://127.0.0.1:8080").rstrip("/")
PORT = int(os.environ.get("PORT", "8081"))
TIMEOUT = float(os.environ.get("TIMEOUT_S", "5"))


class Handler(http.server.SimpleHTTPRequestHandler):
    """Static file server for dist/, with `/v1/*` proxied to the collector.

    Only do_GET is defined, so any other method gets a 501 from the stdlib base
    class. SimpleHTTPRequestHandler's own path translation handles traversal.
    """

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(DIST), **kw)

    def do_GET(self):
        if self.path == "/v1" or self.path.startswith("/v1/"):
            self.proxy()
        else:
            super().do_GET()

    def proxy(self):
        # The upstream base is fixed; only the path and query come from the
        # request, and both are re-quoted rather than pasted through.
        parts = urllib.parse.urlsplit(self.path)
        url = urllib.parse.urlunsplit(
            ("", "", COLLECTOR + urllib.parse.quote(parts.path), parts.query, "")
        )
        try:
            with urllib.request.urlopen(url, timeout=TIMEOUT) as upstream:
                body, status = upstream.read(), upstream.status
                ctype = upstream.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            # The collector reports real conditions this way (e.g. /v1/health
            # 503 when it does not hold the writer lease). Pass them through so
            # the console can render them instead of showing a transport error.
            body, status = e.read(), e.code
            ctype = e.headers.get("Content-Type", "application/json")
        except OSError as e:
            body = b'{"error":"collector_unreachable","message":%s}' % _json_str(str(e))
            status, ctype = 502, "application/json"

        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        if not os.environ.get("QUIET"):
            super().log_message(fmt, *args)


def _json_str(s):
    return ('"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"').encode()


if __name__ == "__main__":
    if not (DIST / "index.html").exists():
        sys.exit(f"no build at {DIST} — run `npm run build` in ui/ first")
    # ponytail: ThreadingHTTPServer with the default queue; a single operator on
    # localhost never exceeds it. Put it behind a real server if that changes.
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"console   http://127.0.0.1:{PORT}\ncollector {COLLECTOR}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()
