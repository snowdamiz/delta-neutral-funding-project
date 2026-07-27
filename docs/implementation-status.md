# Implementation status

| Milestone | State | Evidence |
|---|---|---|
| 0. Contracts and qualification | Complete for paper scope | Phoenix is selected for read-only paper data, JitoSOL identities and mechanics are documented, schema v1 and strategy contracts are frozen, and every required Mesh capability has a probe or explicit bridge/defer decision |
| 1. Financial correctness and Mesh slice | Complete | Checked fixed-point math, cross-boundary parsers, native Solana read and transaction-inspection packages, runtime telemetry, tests, and a compiled collector candidate are pinned to Mesh `728f534` |
| 2. Production-like Mesh foundation | Complete | Local Docker services, fenced renewable writer lease with graceful release, accepted-request drain, database-authoritative startup reconciliation, pre-allocation HTTP request limits, bounded-delivery overload/concurrency and GC probes, runtime-native and DB-backed bounded-cardinality metrics, Prometheus-tested safety alerts, twelve Grafana panels, health, structured logs, database pooling, memory/PID caps, restart policies, and bounded local logs are present |
| 3. Read-only adapter and recorder | Complete for paper scope | HMAC-authenticated synthetic and keyless Phoenix/Solana/Jupiter paper captures are normalized to integer atoms with TLS-only remote endpoints, ordered provider failover, coherent-slot checks, idempotent funding records, gap resnapshot, and independent 1×/2× exact-size quote ladders; credentialed access remains a live gate |
| 4. Paper broker and accounting | Complete | Independent and synchronized entries, fills, rehedging, exits, realized multi-book funding, ledger-backed JitoSOL valuation, and a separate epoch-aware direct-unstake counterfactual with actual cooldown funding are implemented |
| 5. State machines, opportunity, and risk | Complete for paper scope | Fail-closed lifecycles, durable per-snapshot risk decisions, source-gap/staleness and authoritative margin/liquidation breakers, verified startup/operator reconciliation, authenticated controls, durable exits, emergency flattening, and a guarded CLI are implemented |
| 6. Replay and differential validation | Complete for local deterministic scope | The exact Docker adoption gate covers clean Git/Mesh pins, commit-qualified rollback tags, generated parser mutations, bounded-delivery/concurrency/GC/supervisor probes, adapter tests, Rust tests/Clippy, shared vectors, six exact replay traces including doubled execution costs, attested SBOMs, fixed high/critical image scans, and native-Mesh/adapter JitoSOL NAV comparison; elapsed calibration remains milestone 7 evidence |
| 7. 30-day paper soak | Qualification continuity failed | The preserved schema-28 run beginning at `1785165668457` recorded a 777,664 ms source gap against the 60,000 ms limit. Evidence remains intact; a new final-release run must begin from its real start time after the candidate is frozen |
| 8. Shadow and P1 Mesh expansion | In progress | `mesh-solana` 0.2 now builds and inspects legacy/v0/ALT messages, recent blockhash requests, compute-budget and SPL/ATA instructions, unsigned simulation requests, and simulation responses; a networkless collector proof exposes no signing/submission path. Strict simulation-only Jupiter/perp fixtures still pass the independent Rust policy dry-run, and native JitoSOL read/WSS proofs remain green. Credentialed exact Jupiter/perp construction, live RPC/venue differential simulation, sustained feed soak, rollback rehearsal, and authoritative calibration remain gated |
| 9. Locked executor | Gated before live integration | The independent Rust shadow policy revalidates canonical intents, command identity, allowlists, notional/price/fee/compute caps, simulation deltas, its kill switch, and signer isolation; remote signer and submission paths are deliberately absent pending soak, operator, and security gates |
| 10. Live canary | Not approved | Requires every go-live gate and explicit operator approval |

Live execution is intentionally unavailable. The local deployment has no
executor service or host-published database, uses segmented networks and
non-root read-only application containers, and rejects non-paper startup.
Completing local code does not complete the 30-day soak or authorize a
transaction.

The effective paper policy is parsed once through a shared strict Mesh contract
and deterministically fingerprinted. A changed application commit, Mesh commit,
or policy cannot attach to an existing strategy run or mutate its
build/comparison metadata. Application and Mesh revisions are compiled into the
collector rather than accepted from overridable runtime environment variables.
