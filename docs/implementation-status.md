# Implementation status

| Milestone | State | Evidence |
|---|---|---|
| 0. Contracts and qualification | In progress | Strategy contracts and schema v1 are frozen; authoritative venue probes remain |
| 1. Financial correctness and Mesh slice | Complete | Checked fixed-point math, cross-boundary parsers, tests, and a compiled collector are pinned to Mesh `105b55e` |
| 2. Production-like Mesh foundation | In progress | Local Docker services, fenced renewable writer lease, health, metrics, structured logs, and database pooling are present |
| 3. Read-only adapter and recorder | In progress | HMAC-authenticated synthetic market and funding events are recorded idempotently; live venue reads remain |
| 4. Paper broker and accounting | In progress | Dual atomic entries, fills, rehedging, exits, valuation attribution, and realized funding ledger entries are implemented |
| 5. State machines, opportunity, and risk | In progress | Fail-closed lifecycles, reconciliation, authenticated controls, durable exits, emergency flattening, and a guarded CLI run; margin/source breakers remain |
| 6. Replay and differential validation | In progress | A networkless Docker CLI replays the pinned calm bundle deterministically with virtual time, ordering/duplicate checks, exact config/toolchain pins, dual decisions, and funding traces; stress bundles and differential vectors remain |
| 7. 30-day paper soak | Blocked on elapsed observation time | Must not be simulated or backdated |
| 8. Shadow | Pending | No signer reachability allowed |
| 9. Locked executor | Pending | Local policy tests only |
| 10. Live canary | Not approved | Requires every go-live gate and explicit operator approval |

Live execution is intentionally unavailable. Completing local code does not
complete the 30-day soak or authorize a transaction.
