# Implementation status

| Milestone | State | Evidence |
|---|---|---|
| 0. Contracts and qualification | In progress | Strategy contracts and schema v1 are frozen; authoritative venue probes remain |
| 1. Financial correctness and Mesh slice | Complete | Checked fixed-point math, cross-boundary parsers, tests, and a compiled collector are pinned to Mesh `9cf951c` |
| 2. Production-like Mesh foundation | In progress | Local Docker services, fenced renewable writer lease, database-authoritative startup reconciliation, bounded-delivery overload/concurrency and GC probes, health, metrics, structured logs, and database pooling are present; long elapsed soak remains |
| 3. Read-only adapter and recorder | In progress | HMAC-authenticated synthetic and opt-in Phoenix/Solana/Jupiter paper captures are normalized to integer atoms with ordered provider failover, coherent-slot checks, idempotent funding records, and gap resnapshot; credentialed soak capture remains |
| 4. Paper broker and accounting | In progress | Independent and synchronized entries, fills, rehedging, exits, realized multi-book funding, ledger-backed JitoSOL valuation, and a separate epoch-aware direct-unstake counterfactual with actual cooldown funding are implemented; venue calibration remains |
| 5. State machines, opportunity, and risk | In progress | Fail-closed lifecycles, durable per-snapshot risk decisions, source-gap/staleness and authoritative margin/liquidation breakers, verified startup/operator reconciliation, authenticated controls, durable exits, emergency flattening, and a guarded CLI run; venue calibration remains |
| 6. Replay and differential validation | In progress | The Docker adoption gate requires the exact clean Mesh pin, generated parser mutations, bounded-delivery/concurrency/GC/supervisor probes, adapter tests, Rust tests/Clippy, shared vectors, and five exact replay traces; authoritative fixtures and elapsed memory soak remain |
| 7. 30-day paper soak | Blocked on elapsed observation time | Must not be simulated or backdated |
| 8. Shadow | In progress | Isolated adapter-built Jupiter/perp actions pass the Rust dry-run, account/fee/compute deltas are durably compared with paper estimates, and unknown results block retry until reconciliation; authoritative calibration remains |
| 9. Locked executor | In progress | The independent Rust policy revalidates canonical intents, command identity, allowlists, notional/price/fee/compute caps, and simulation deltas with signer and submission disabled; live signer integration remains gated |
| 10. Live canary | Not approved | Requires every go-live gate and explicit operator approval |

Live execution is intentionally unavailable. Completing local code does not
complete the 30-day soak or authorize a transaction.
