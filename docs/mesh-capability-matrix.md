# Mesh capability matrix

Candidate runtime commit: `bea7d2159572d096eafea2577c2887ef7342ce86`

The pin is a source commit, not an untracked application patch.

| ID | State | Evidence / decision |
|---|---|---|
| MESH-FIN-001 | Implemented | `Checked.*`; Rust wide-intermediate tests and Mesh e2e fixture |
| MESH-FIN-002 | Project-local | Nominal finance wrappers use `Checked.*` |
| MESH-TIME-001 | Implemented | monotonic nanoseconds and checked duration helpers |
| MESH-TEST-001 | Project-local | system/replay/test clock values are passed explicitly |
| MESH-TEST-002 | Implemented | stable explicit-state xorshift64* generator |
| MESH-ACTOR-001 | Implemented | item/byte-bounded reject/drop/latest channels; saturation and coalescing are observable; producers return an explicit contention/full result without waiting |
| MESH-PROC-001 | Implemented | async-signal-safe SIGINT/SIGTERM flag, accepted-request drain, and native `Process.exit(Int)` |
| MESH-OBS-001 | Project-local | JSON-line logger; secret fields excluded |
| MESH-METRICS-001 | Implemented | pure Mesh fixed-name Prometheus rendering over bounded runtime telemetry plus one database snapshot |
| MESH-PROTO-001 | Project-local | JSON Schema v1 plus shared fixtures |
| MESH-BYTES/CODEC/NUM | Implemented | Binary-safe bytes, strict codecs, and checked U64/U128 arithmetic are native Mesh features |
| MESH-NATIVE | Implemented | Manifest-gated native archives are hash-verified and linked |
| MESH-WS/HTTP | Implemented | Scheduler-aware bounded clients with cancellation and deterministic limits; a compiled bounded slot subscription validates its acknowledgement and lineage against a separate HTTP read |
| MESH-BORSH/ANCHOR/SOL-READ | Implemented | Native package tests decode exact SPL/JitoSOL layouts and typed bounded RPC payloads; compiled one-shot differentials validate epoch, atomic NAV, and slot agreement. Burn-only mint deficits retain the conservative stake-pool denominator, while mint inflation fails closed; the qualified TypeScript adapter remains the production paper feed pending sustained differential soak |
| MESH-SOL-TX | Implemented; bridge retained | `mesh-solana` 0.2 ingests and orders bounded Jupiter instructions; compiles and serializes high-level legacy/v0 messages and resolved address lookups; reads recent blockhashes; builds compute-budget, SPL, and ATA instructions; builds unsigned simulation envelopes; parses simulation results; and emits byte-free message/instruction allowlist reports. The TypeScript/Rust bridge remains until credentialed exact-action differentials and rollback qualify |
| MESH-SECRET/CRYPTO/SIGNER | Deferred | absent from paper and shadow deployments |

## Runtime verification

At the pinned revision:

```text
cargo fmt --all -- --check
cargo test -p mesh-rt env::tests::test_env_args
cargo test -p meshc --test e2e e2e_checked_mul_div
cargo test -p meshc --test e2e e2e_monotonic_duration
cargo test -p meshc --test e2e e2e_bounded_channel
cargo test -p mesh-rt channel::tests
cargo test -p mesh-rt actor::mailbox::tests::test_mailbox_concurrent_push
cargo test -p mesh-rt http::server::tests::request_parser_rejects_unbounded_or_ambiguous_input
cargo test -p meshc --test e2e_stdlib e2e_http_server_drains_accepted_requests_before_returning
cargo test -p meshc --test e2e_stdlib e2e_cluster_telemetry_is_available_as_a_typed_map
cargo test -p meshc --test e2e_actors gc_bounded_memory
cargo test -p meshc --test e2e_supervisors supervisor_restarts_crashed_permanent_child
cargo test -p meshc --test e2e e2e_deterministic_random
cargo test -p meshc --test e2e e2e_process_shutdown_signal
cargo test -p meshc --test e2e e2e_process_exit_sets_the_native_status_code
cargo test -p meshc --test e2e e2e_nested_and
cargo test -p meshc --test e2e_borsh_native
cargo test -p meshc --test e2e_anchor_package
cargo test -p meshc --test e2e_http_client
cargo test -p meshc --test e2e_solana_read_package
cargo test -p meshc --test tooling_e2e test_test_runs_mesh_solana_path_dependency
```

Collector capability probes cover HTTP, JSON, PostgreSQL, actors, supervisors,
timers, shutdown, and the project-local packages before milestone zero closes.
Each exact build persists all 23 results in schema 29 and exposes them at
`/v1/capabilities`; a missing or duplicate result rejects startup.
