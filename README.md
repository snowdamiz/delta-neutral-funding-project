# Delta-neutral funding collector

Local-first, Mesh-owned paper and shadow system for comparing:

- long SOL + short SOL-PERP (`SOL_CONTROL`);
- long JitoSOL + short SOL-PERP (`JITOSOL_CARRY`);
- long the top-ranked spot asset + short its perpetual
  (`CROSS_ASSET_FUNDING`);
- long the top-ranked asset perpetual + borrowed/sold spot when funding is
  deeply negative (`NEGATIVE_FUNDING_REVERSE`);
- buy JitoSOL below protocol NAV, short its NAV-equivalent SOL exposure, and
  redeem through the better modeled exit (`JITOSOL_NAV_DISCOUNT`);
- short the higher-realized-funding perpetual and long the lower-funding
  perpetual for the same asset (`CROSS_VENUE_FUNDING`);
- aggregate, mirror, or fade configured Hyperliquid wallets
  (`HYPERLIQUID_WALLET_FLOW`, `HYPERLIQUID_WALLET_MIRROR`,
  `HYPERLIQUID_WALLET_FADE`).

Paper mode is the default and the only currently approved mode. The repository
contains no private key and no route from the paper deployment to a signer.

## Local development

`dev.sh` brings up everything — the six compose services and the operator
console — and waits for every healthcheck before handing over:

```sh
./dev.sh              # stack + console on http://127.0.0.1:5173
./dev.sh stack        # stack only
./dev.sh build        # force an image rebuild first
./dev.sh status       # service state and URLs
./dev.sh down         # stop the stack; volumes are kept
```

Building is opt-in because the collector image compiles the Mesh toolchain from
`../mesh-lang` — LLVM, Rust, and the `meshc` test suite — before it reaches this
project's sources. `dev.sh` builds only when the image is missing, so ordinary
runs start in seconds. Use `./dev.sh build` after changing Mesh or collector
sources.

The stack keeps running when the console exits, so closing the console never
interrupts a soak. The underlying compose invocation still works directly:

```sh
docker compose up --build
```

The default adapter is deterministic and synthetic. Read-only authoritative
paper capture is opt-in and fails closed; it never falls back to synthetic data:

```sh
ADAPTER_MODE=authoritative \
docker compose up --build
```

That mode combines the Phoenix SOL orderbook and hourly funding record, JitoSOL
stake-pool and mint accounts from Solana RPC, and exact-size Jupiter spot
quotes. Jupiter's bounded keyless access is sufficient for the default
fifteen-second post-capture interval; the 60-second source-age limit covers a
complete six-request capture cycle. `JUPITER_API_KEY` enables a separately
managed higher-rate quota. Comma-separated `PHOENIX_URLS`, `SOLANA_RPC_URLS`,
and `JUPITER_URLS` provide ordered failover.

The Phase 2 paper path also reads pinned Kamino reserve metrics. It subtracts
live variable borrow APY from negative funding, requires 2× notional in
available borrow liquidity, and exits on the current observation when borrow
cost reaches funding. `KAMINO_URLS` provides ordered failover;
`KAMINO_LENDING_MARKET` and `KAMINO_BORROW_RESERVES` pin identities. See the
[Kamino qualification](docs/kamino-qualification.md); live borrowing remains
unapproved.

Opportunity carry is projected across `EXPECTED_HOLD_HOURS` (72 by default)
and rejected when costs cannot break even inside `MAXIMUM_BREAK_EVEN_HOURS`
(48 by default). JitoSOL reward carry comes from the stake pool's completed
epoch exchange-rate growth, reduced by `JITOSOL_REWARD_HAIRCUT_PPM` (250000,
or 25%); it needs no secret or advertised APY.

The Phase 3 NAV-discount book reuses the same accepted JitoSOL snapshot and
direct-unstake state machine. It compares executable purchase and instant-exit
quotes with protocol redemption after the configured withdrawal, chain, hedge,
delay, funding, and risk costs. Positive funding may improve a real discount
but cannot create eligibility when the executable ask is at or above NAV.

The Phase 4 cross-venue book selects one asset across two qualified perpetual
venues from realized funding prints. It sizes equal and opposite legs, charges
both-leg costs, values mark divergence, maintains each venue's margin
independently, and emergency-flattens both legs when either exit becomes
uncertain. Hyperliquid publishes a usable maintenance rate; the current second
venue remains fail-closed until its margin and executable-depth evidence is
qualified.

Phase 5 indexes the explicit Hyperliquid cohort configured in the console's
Markets → Wallet consistency panel. The authenticated update is stored in
PostgreSQL and the adapter reloads it without a restart; `GET /v1/wallets/config`
exposes the current internal cohort. It scores only evidence
available before each decision, records measured API latency and executable
copy-book slippage, and papers aggregate-flow, mirror, and fade modes at locally
bounded size. The wallet panel also exposes the 60-day/20-decision gate against
holding SOL and Phase 1. An empty cohort is valid and keeps all three modes
pending.

## Operator console

`ui/` is a React console over the read API. It is driven by the collector's
strategy catalog (`GET /v1/strategies`) and enumerates nothing itself: the
overview shows signal state, one card per registered strategy, forward and
reverse funding leaderboards, and the capability matrix; opening a card shows
that strategy against the benchmark it declares, its positions against their
pinned margin and liquidation floors, attribution, risk decisions,
opportunities, and ledger. The open strategy lives in the URL fragment
(`#jitosol_carry`), so a detail view is linkable.

Registering a strategy is a row in the catalog read model
(`mesh/packages/read_models.mpl`); the console needs no change to render it.
Adding one with no portfolio runs yet is the intended way to check that — it
appears as `not registered` with empty evidence rather than a broken card.

```sh
cd ui
npm install
npm run dev          # http://127.0.0.1:5173, proxies /v1 to the collector
```

`COLLECTOR=http://host:port npm run dev` targets a different collector. For a
build without a Node runtime, `npm run build && python3 serve.py` serves `dist/`
with the same proxy on port 8081.

The local paper console has Start and Stop controls for resume and pause-all.
Its localhost proxy signs those two requests with `OPERATOR_HMAC_SECRET`
(`local-operator-only-change-me` by default), so the secret never reaches the
browser. Destructive exits, flattening, and resets stay with `bin/collector`.

Controls carry a strategy scope (`/operator/pause-all?strategy=<id>`), which the
proxy signs into the operator command's reason so the evidence trail records
which strategy an operator acted on. The collector's pause state is a singleton,
so the switch itself lives in Signal and cards say so; a strategy that declares
`controlScope: "strategy"` in the catalog gets its own control with no console
change. `npm test` covers the catalog contract, scoped control signing, and
fixed-point conversion and arithmetic.

## Operator commands

Read-only operator commands use `bin/collector` directly. Mutations require the
separate operator secret, and paper exits/flattening also require the explicit
`--approve-paper` argument:

```sh
OPERATOR_HMAC_SECRET=local-operator-only-change-me \
  bin/collector exit jitosol-carry "manual paper exit" --approve-paper
```

`paper-reset` is intentionally stricter: pause all entries, flatten every paper
portfolio, and reconcile before using:

```sh
bin/collector paper-reset \
  --initial-usdc 5000 \
  --initial-collateral 500 \
  --approve-paper-reset
```

The collateral must match the pinned runtime
configuration. A successful reset atomically clears paper evidence, recreates
opening ledgers, preserves build/operator audit records, and remains paused.

Deterministic replay uses the same collector image without a network or writable
root filesystem:

```sh
bin/collector replay \
  --bundle replay/bundles/calm-v1.jsonl \
  --config replay/configs/baseline-v1.json

bin/collector verify-toolchain

scripts/check-replay.sh
scripts/check-toolchain-rollback.sh
scripts/check-database.sh
scripts/check-toolchain.sh
scripts/check-shutdown.sh
scripts/check-shadow-persistence.sh
scripts/check-native-solana-read.sh
scripts/check-native-solana-subscription.sh
scripts/check-native-solana-instruction.sh
scripts/check-recovery.sh
scripts/check-security.sh
scripts/check-observability.sh
scripts/soak-report.sh
scripts/runtime-stability-report.sh
```

The replay gate runs the calm, volatile, liquidity-loss, epoch-boundary, and
deterministic-failure bundles twice and checks their exact outcome hashes.
The rollback gate replays all six bundles on the candidate and prior pinned
Mesh images and requires identical economic traces after release identity is
removed from the comparison.
The database gate applies every migration and contract test to fresh temporary
PostgreSQL storage.
The toolchain gate additionally verifies the exact clean Mesh checkout and runs
the Mesh, TypeScript, and Rust conformance suites while building their images.
It requires a clean project checkout, compiles the Git and Mesh revisions into
the collector, labels every image, and creates commit-qualified local image
tags for rollback.
The native instruction gate inspects both one raw instruction and a complete
Jupiter build instruction set in a read-only container with networking disabled.
The shadow persistence check builds Jupiter and perp actions without network
access, dry-runs the independent Rust policy, and records paper/simulation
deltas through the authenticated Mesh API.
The native Solana check runs the compiled Mesh collector as a read-only
mainnet RPC client and compares its independently validated JitoSOL epoch and
atomic NAV with the latest authoritative adapter observation.
The subscription check opens one bounded Mesh WebSocket slot subscription,
validates its acknowledgement and slot lineage, and compares the observed slot
with a separate native HTTP read.
The instruction check runs without network access and proves the compiled Mesh
collector can parse bounded Jupiter raw-instruction JSON and compile high-level
instructions into legacy and v0 messages before any signing path exists.
The shutdown check proves SIGTERM drains accepted requests, releases the fenced
writer lease, and exits cleanly. The recovery check includes that drill and
proves a PostgreSQL backup can be restored and reconciled in isolated temporary
Docker storage.
The security check verifies the paper-only network topology and non-root users,
extracts each image's attested CycloneDX SBOM, scans fixed high/critical
vulnerabilities with digest-pinned Trivy, and proves startup fails closed.
The observability check validates the live bounded-cardinality Prometheus
exposition, build identity, alert rules, and all twelve Grafana panels. Alert
delivery remains intentionally unconfigured until an operator destination is
provided.
The soak report derives authoritative duration, continuity, paired-decision,
funding-interval, epoch-transition, and unresolved-safety evidence from
PostgreSQL. Collector startup rejects an application, Mesh, or configuration
identity that differs from the release already pinned to the paper run.
Prometheus retains 35 days within a 2 GB cap for the matching runtime-stability
report, which records memory, mailbox, run-queue, restart, rejection, outbox,
PostgreSQL, and Prometheus-storage evidence over the exact soak window.

Milestone status and open gates are tracked in
[`docs/implementation-status.md`](docs/implementation-status.md). Every
Section 27 requirement and its evidence owner is tracked in
[`docs/go-live-gates.md`](docs/go-live-gates.md).
