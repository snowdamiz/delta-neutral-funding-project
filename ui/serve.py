#!/usr/bin/env python3
"""Serve the built console (`npm run build`) with the collector proxied same-origin.

`npm run dev` already does this via Vite's dev proxy; this is the equivalent for
a production build, with no Node runtime required.

The bounded local paper controls are signed by this localhost server. Database
reset is the one destructive route and requires an exact confirmation phrase.

    python3 ui/serve.py                  # http://127.0.0.1:8081
    PORT=9000 COLLECTOR=http://127.0.0.1:8080 python3 ui/serve.py
"""

import hashlib
import hmac
import http.client
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

DIST = Path(__file__).resolve().parent / "dist"
COLLECTOR = os.environ.get("COLLECTOR", "http://127.0.0.1:8080").rstrip("/")
PORT = int(os.environ.get("PORT", "8081"))
TIMEOUT = float(os.environ.get("TIMEOUT_S", "5"))
OPERATOR_SECRET = os.environ.get("OPERATOR_HMAC_SECRET", "local-operator-only-change-me")
PROJECT = Path(__file__).resolve().parent.parent
RESET_APPROVAL = "WIPE PAPER DATABASE"
RESET_LOCK = threading.Lock()


class Handler(http.server.SimpleHTTPRequestHandler):
    """Static file server for dist/, with `/v1/*` proxied to the collector.

    SimpleHTTPRequestHandler's own path translation handles traversal.
    """

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(DIST), **kw)

    def do_GET(self):
        if self.path == "/v1" or self.path.startswith("/v1/"):
            self.proxy_get()
        else:
            super().do_GET()

    def do_POST(self):
        # Mirrors ui/operator.ts, which signs the same controls for the Vite
        # dev proxy: same bodies, same scope handling, same reason strings.
        requested = urllib.parse.urlsplit(self.path)
        if requested.path == "/operator/reset-database":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length > 1024:
                    raise ValueError
                incoming = json.loads(self.rfile.read(length))
                if incoming != {"approval": RESET_APPROVAL}:
                    raise ValueError
            except (TypeError, ValueError, json.JSONDecodeError):
                self.respond(b'{"error":"reset_approval_required"}', 400, "application/json")
                return
            if not RESET_LOCK.acquire(blocking=False):
                self.respond(b'{"error":"database_reset_in_progress"}', 409, "application/json")
                return
            try:
                subprocess.run(
                    [str(PROJECT / "dev.sh"), "reset-db", "--approve-paper-reset"],
                    cwd=PROJECT,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=180,
                    check=True,
                )
                self.respond(b'{"status":"restarted"}', 200, "application/json")
            except (OSError, subprocess.SubprocessError):
                self.respond(b'{"error":"database_reset_failed"}', 500, "application/json")
            finally:
                RESET_LOCK.release()
            return
        if requested.path in ("/operator/wallets/config", "/operator/solana-wallets/config"):
            solana = requested.path == "/operator/solana-wallets/config"
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length > 8192:
                    self.respond(b'{"error":"request_too_large"}', 413, "application/json")
                    return
                incoming = json.loads(self.rfile.read(length))
                wallets = incoming["wallets"]
                maximum = 100 if solana else 50
                if (
                    set(incoming) != {"wallets"}
                    or not isinstance(wallets, list)
                    or len(wallets) > maximum
                    or any(not isinstance(wallet, str) for wallet in wallets)
                ):
                    raise ValueError
                wallets = [wallet.strip() if solana else wallet.strip().lower() for wallet in wallets]
                pattern = r"[1-9A-HJ-NP-Za-km-z]{32,44}" if solana else r"0x[0-9a-f]{40}"
                if (
                    any(not re.fullmatch(pattern, wallet) for wallet in wallets)
                    or len(set(wallets)) != len(wallets)
                ):
                    raise ValueError
            except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                self.respond(b'{"error":"invalid_wallet_config"}', 400, "application/json")
                return
            payload = {
                "reason": (
                    "Solana wallet cohort updated from local operator console"
                    if solana else "wallet cohort updated from local operator console"
                ),
                "wallets": wallets,
            }
            action = "solana-wallet-flow/config" if solana else "wallets/config"
        elif strategy_control := re.fullmatch(
            r"/operator/strategies/([a-z0-9_]{1,64})/(start|stop)",
            requested.path,
        ):
            strategy, verb = strategy_control.groups()
            action = f"strategies/{strategy}/{verb}"
            payload = {
                "reason": (
                    f"{'started' if verb == 'start' else 'stopped'} "
                    f"from local operator console (strategy: {strategy})"
                )
            }
        elif strategy_mode := re.fullmatch(
            r"/operator/strategies/([a-z0-9_]{1,64})/(arm-live|disarm-live)",
            requested.path,
        ):
            strategy, verb = strategy_mode.groups()
            live = verb == "arm-live"
            action = f"strategies/{strategy}/mode"
            payload = {"mode": "live" if live else "paper"}
            if live:
                payload["approval"] = "ARM LIVE TRADING"
            payload["reason"] = (
                f"{'armed live trading' if live else 'disarmed live trading'} "
                f"from local operator console (strategy: {strategy})"
            )
        elif requested.path in ("/operator/pause-all", "/operator/resume"):
            action = requested.path.removeprefix("/operator/")
            verb = "started" if action == "resume" else "stopped"
            payload = {"reason": f"{verb} from local operator console"}
        else:
            self.send_error(404)
            return
        body = json.dumps(payload, separators=(",", ":")).encode()
        key = f"console-{int(time.time() * 1000)}-{uuid.uuid4()}"
        signature = hmac.new(
            OPERATOR_SECRET.encode(), f"{key}\n".encode() + body, hashlib.sha256
        ).hexdigest()
        parts = urllib.parse.urlsplit(COLLECTOR)
        connection = (
            http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
        )(parts.hostname, parts.port, timeout=TIMEOUT)
        try:
            connection.request(
                "POST",
                f"{parts.path.rstrip('/')}/v1/{action}",
                body,
                {
                    "content-type": "application/json",
                    "x-idempotency-key": key,
                    "x-operator-signature": signature,
                },
            )
            upstream = connection.getresponse()
            self.respond(
                upstream.read(),
                upstream.status,
                upstream.getheader("Content-Type", "application/json"),
            )
        except OSError as e:
            self.respond(
                b'{"error":"collector_unreachable","message":%s}' % _json_str(str(e)),
                502,
                "application/json",
            )
        finally:
            connection.close()

    def proxy_get(self):
        # The upstream base is fixed; only the path and query come from the
        # request, and both are re-quoted rather than pasted through.
        parts = urllib.parse.urlsplit(self.path)
        url = urllib.parse.urlunsplit(
            ("", "", COLLECTOR + urllib.parse.quote(parts.path), parts.query, "")
        )
        self.forward(urllib.request.Request(url))

    def forward(self, request):
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as upstream:
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

        self.respond(body, status, ctype)

    def respond(self, body, status, ctype):
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
