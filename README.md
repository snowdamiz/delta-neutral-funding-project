# Delta-neutral funding collector

Local-first, Mesh-owned paper and shadow system for comparing:

- long SOL + short SOL-PERP (`SOL_CONTROL`);
- long JitoSOL + short SOL-PERP (`JITOSOL_CARRY`).

Paper mode is the default and the only currently approved mode. The repository
contains no private key and no route from the paper deployment to a signer.

## Local development

The complete stack is started with Docker Compose:

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
quotes. Jupiter's bounded keyless access is sufficient for the default ten-second
capture interval; `JUPITER_API_KEY` enables a separately managed higher-rate
quota. Comma-separated `PHOENIX_URLS`, `SOLANA_RPC_URLS`, and `JUPITER_URLS`
provide ordered failover.

Read-only operator commands use `bin/collector` directly. Mutations require the
separate operator secret, and paper exits/flattening also require the explicit
`--approve-paper` argument:

```sh
OPERATOR_HMAC_SECRET=local-operator-only-change-me \
  bin/collector exit jitosol-carry "manual paper exit" --approve-paper
```

Deterministic replay uses the same collector image without a network or writable
root filesystem:

```sh
bin/collector replay \
  --bundle replay/bundles/calm-v1.jsonl \
  --config replay/configs/baseline-v1.json

scripts/check-replay.sh
scripts/check-database.sh
scripts/check-toolchain.sh
scripts/check-shutdown.sh
scripts/check-shadow-persistence.sh
scripts/check-recovery.sh
scripts/check-security.sh
scripts/check-observability.sh
scripts/soak-report.sh
```

The replay gate runs the calm, volatile, liquidity-loss, epoch-boundary, and
deterministic-failure bundles twice and checks their exact outcome hashes.
The database gate applies every migration and contract test to fresh temporary
PostgreSQL storage.
The toolchain gate additionally verifies the exact clean Mesh checkout and runs
the Mesh, TypeScript, and Rust conformance suites while building their images.
It requires a clean project checkout, embeds the Git revision in every image,
and creates commit-qualified local image tags for rollback.
The shadow persistence check builds Jupiter and perp actions without network
access, dry-runs the independent Rust policy, and records paper/simulation
deltas through the authenticated Mesh API.
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
review.

Milestone status and open gates are tracked in
[`docs/implementation-status.md`](docs/implementation-status.md). Every
Section 27 requirement and its evidence owner is tracked in
[`docs/go-live-gates.md`](docs/go-live-gates.md).
