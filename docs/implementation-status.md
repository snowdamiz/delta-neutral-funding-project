# Implementation status

| Milestone | State | Evidence |
|---|---|---|
| 0. Contracts and qualification | In progress | Strategy contracts and schema v1 are frozen; authoritative venue probes remain |
| 1. Financial correctness and Mesh slice | Complete | Checked fixed-point math, cross-boundary parsers, tests, and a compiled collector are pinned to Mesh `105b55e` |
| 2. Production-like Mesh foundation | In progress | Local Docker services, fenced renewable writer lease, database-authoritative startup reconciliation, health, metrics, structured logs, and database pooling are present |
| 3. Read-only adapter and recorder | In progress | HMAC-authenticated synthetic market and funding events are recorded idempotently and sequence gaps require resnapshot; live venue reads remain |
| 4. Paper broker and accounting | In progress | Dual atomic entries, fills, rehedging, exits, ledger-backed JitoSOL valuation attribution, realized funding, and restart-safe partial-entry compensation are implemented |
| 5. State machines, opportunity, and risk | In progress | Fail-closed lifecycles, durable per-snapshot risk decisions, source-gap/staleness and authoritative margin/liquidation breakers, verified startup/operator reconciliation, authenticated controls, durable exits, emergency flattening, and a guarded CLI run; venue calibration remains |
| 6. Replay and differential validation | In progress | The Docker adoption gate requires the exact clean Mesh pin, 13 Mesh suites, adapter tests, Rust tests/Clippy, shared fixed-point/NAV/funding/delta/intent-hash vectors, and five exact replay traces; parser fuzz/stress remains |
| 7. 30-day paper soak | Blocked on elapsed observation time | Must not be simulated or backdated |
| 8. Shadow | Pending | No signer reachability allowed |
| 9. Locked executor | Pending | Local policy tests only |
| 10. Live canary | Not approved | Requires every go-live gate and explicit operator approval |

Live execution is intentionally unavailable. Completing local code does not
complete the 30-day soak or authorize a transaction.
