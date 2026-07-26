# Mesh capability matrix

Pinned runtime commit: `ac039696c3c60e2fba15e45184590212cb785c64`

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
| MESH-BYTES/CODEC/NUM | Bridged | TypeScript adapter transports base64 and decimal strings |
| MESH-WS/HTTP/SOL-READ | Bridged | read-only TypeScript adapter |
| MESH-SOL-TX | Bridged | TypeScript action builder plus independently constrained Rust dry-run; no signer/submission |
| MESH-SECRET/CRYPTO/SIGNER | Deferred | absent from paper and shadow deployments |

## Runtime verification

At the pinned revision:

```text
cargo fmt --all -- --check
cargo test -p mesh-rt env::tests::test_env_args
cargo test -p meshc --test e2e e2e_checked_mul_div
cargo test -p meshc --test e2e e2e_monotonic_duration
cargo test -p meshc --test e2e e2e_bounded_channel
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
```

Collector capability probes cover HTTP, JSON, PostgreSQL, actors, supervisors,
timers, shutdown, and the project-local packages before milestone zero closes.
Each exact build persists all 23 results in schema 27 and exposes them at
`/v1/capabilities`; a missing or duplicate result rejects startup.
