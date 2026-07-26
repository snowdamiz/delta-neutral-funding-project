# Go-live evidence ledger

Audit date: 2026-07-26. Live is not approved.

`PASS` means reproducible local evidence exists. `COLLECTING` requires real
elapsed authoritative observations. `OPERATOR` needs an eligible human,
account, wallet, or alert destination. `GATED` is deliberately absent until
earlier gates pass. `PARTIAL` has useful evidence but is not a completed gate.

## Strategy and JitoSOL

| Section 27 gate | State | Evidence or owner |
|---|---|---|
| 30 days continuous dual-paper operation | COLLECTING | `scripts/soak-report.sh`; PostgreSQL schema 27 |
| 100 funding intervals | COLLECTING | `funding_interval_count` in the durable soak report |
| Several epoch/reward transitions | COLLECTING | `epoch_transition_count` and JitoSOL valuation events |
| Acceptable cost-complete JitoSOL P&L | COLLECTING | `/v1/pnl`, `/v1/pnl-comparison`, soak acceptance |
| SOL control comparison | COLLECTING | Independent and synchronized comparison groups are active |
| Reward/basis/cost/rehedge decomposition | COLLECTING | Balanced ledger/read models are implemented; sample is still accruing |
| No dependence on one extreme period | COLLECTING | Requires the full observation window |
| Doubled cost and liquidity-loss stress | PARTIAL | Deterministic doubled-fee/slippage and liquidity-loss golden replays pass; canary calibration still requires the authoritative sample and approved size |
| 1× and 2× canary instant-exit depth | COLLECTING | Independent 1×/2× paper quote ladders exist; canary size is not approved |
| Manual delayed-unstake/hedge runbook | PASS | `docs/runbooks/operations.md` |

## Venue and protocol

| Section 27 gate | State | Evidence or owner |
|---|---|---|
| Funding semantics from docs and records | PASS for paper | `docs/venue-qualification-paper.md`; durable Phoenix funding records |
| Current program/market/mint/API/SDK identities | PARTIAL | Paper identities are pinned; shadow/live startup reverification remains |
| Current fee/margin/liquidation/funding rules | PARTIAL | Public Phoenix parameters are recorded; credentialed/on-chain reproduction remains |
| JitoSOL direct-unstake parameters | PASS for paper | `docs/jitosol-qualification.md`; reverify again at live gate |
| Audits, authority, pause controls, incidents | PARTIAL | Jito audits/authority and Phoenix admin terms reviewed; pre-live incident review remains |
| Operator eligibility and terms | OPERATOR | Explicit legal/jurisdictional confirmation; no circumvention |
| Venue status/support channel | PASS for paper | Official Phoenix documentation and Discord; credentialed escalation remains |

## Mesh toolchain

| Section 27 gate | State | Evidence or owner |
|---|---|---|
| Pinned compiler/runtime build manifest | PASS | Mesh `ac03969`; compiled identity, immutable Docker labels, and fail-closed paper-run release identity |
| Required capability probes | PASS | `scripts/check-toolchain.sh`; `/v1/capabilities`; schema 27 |
| Required P0 capability acceptance | PASS | `MESH-ACTOR-001` enforces item/byte bounds and nonblocking producer contention; all project probes pass |
| Exact cross-language vectors | PASS | Mesh, TypeScript, and Rust conformance suites |
| Golden replay suite | PASS | `scripts/check-replay.sh` |
| Bounded mailbox/concurrency/memory soak | COLLECTING | `scripts/runtime-stability-report.sh`; native/GC/overload probes pass; elapsed deployment evidence remains |
| Compiler/runtime rollback image | PASS | Commit-qualified image produced by `scripts/check-toolchain.sh` |

## Engineering

| Section 27 gate | State | Evidence or owner |
|---|---|---|
| Paper/shadow cannot sign or submit | PASS | No signer service in Compose; network and policy tests reject submission |
| Live startup gates | GATED | No live mode or signer exists yet |
| All transitional states restart-tested | PASS | `db/tests/transitional_restarts.sql`; recovery drill |
| Partial fill/second-leg/unknown outcome | PASS | Mesh broker/recovery and durable shadow-result tests |
| Primary/backup source failover | PASS for paper | Ordered failover adapter tests |
| Schema/sequence recovery | PASS | Adapter contract tests and full-resnapshot path |
| Database restore/reconciliation | PASS | `scripts/check-recovery.sh` |
| Emergency flatten drill | PASS for paper | Authenticated operator/API/CLI and recovery tests |
| Paper-shadow error tolerance | PARTIAL | Durable fixture comparison exists; exact current transaction/order construction, RPC/venue simulation, and authoritative calibration require a qualified shadow identity |

## Security

| Section 27 gate | State | Evidence or owner |
|---|---|---|
| Dedicated wallet and perp subaccount | OPERATOR | Create only after eligibility and venue qualification |
| Minimal capped hot balance | OPERATOR | Fund only after canary approval |
| Isolated executor and signer | GATED | Shadow-only Rust policy exists; signer integration is absent |
| Program/mint/market/account/fee/destination policies | PASS for shadow | Independent Rust allowlist/cap validation |
| Withdrawal-disabled delegation | OPERATOR | Depends on qualified Phoenix account capabilities |
| Private authenticated operator API | PASS | Loopback binding, segmented Docker networks, HMAC/idempotency checks |
| Executor kill switch | PASS for shadow | Rust policy and tests |
| Dependency/SBOM/toolchain/container review | PASS locally | `scripts/check-security.sh`; exact-commit rerun required after every code change |
| No private key in Mesh memory/config/logs | PASS | Paper/shadow images have no signer or private-key input |

## Operations

| Section 27 gate | State | Evidence or owner |
|---|---|---|
| Critical alerts reach operator | OPERATOR | Provide and drill an alert destination |
| Complete dashboards | PASS locally | `scripts/check-observability.sh`; twelve provisioned panels |
| All runbooks tested | PARTIAL | Local recovery/shutdown/operator drills pass; venue/signer/live drills remain |
| Manual venue close documented | PASS | `docs/runbooks/operations.md`; credentialed details remain |
| Live starts paused | GATED | Must be enforced by the future isolated live deployment |
| Canary hard cap below global cap | GATED | Set only after canary notional is approved |
| Operator can disable executor independently | GATED | Requires isolated live executor and operator drill |

## Promotion rule

No `PARTIAL`, `COLLECTING`, `OPERATOR`, or `GATED` row may be treated as
complete. A live implementation may begin only after the elapsed/operator
prerequisites are evidenced, and no transaction may be submitted without a
separate explicit operator approval.
