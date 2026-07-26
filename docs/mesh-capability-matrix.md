# Mesh capability matrix

Pinned runtime commit: `105b55e1029ceba615161901c84d08a9a64885ea`

The pin is a source commit, not an untracked application patch.

| ID | State | Evidence / decision |
|---|---|---|
| MESH-FIN-001 | Implemented | `Checked.*`; Rust wide-intermediate tests and Mesh e2e fixture |
| MESH-FIN-002 | Project-local | Nominal finance wrappers use `Checked.*` |
| MESH-TIME-001 | Implemented | monotonic nanoseconds and checked duration helpers |
| MESH-TEST-001 | Project-local | system/replay/test clock values are passed explicitly |
| MESH-TEST-002 | Implemented | stable explicit-state xorshift64* generator |
| MESH-ACTOR-001 | Partial | item-bounded reject/drop/latest channels; byte bounds and scheduler-aware blocking deferred |
| MESH-PROC-001 | Implemented | async-signal-safe SIGINT/SIGTERM flag plus native `Process.exit(Int)` |
| MESH-OBS-001 | Project-local | JSON-line logger; secret fields excluded |
| MESH-METRICS-001 | Project-local | fixed-name counters/gauges rendered as Prometheus text |
| MESH-PROTO-001 | Project-local | JSON Schema v1 plus shared fixtures |
| MESH-BYTES/CODEC/NUM | Bridged | TypeScript adapter transports base64 and decimal strings |
| MESH-WS/HTTP/SOL-READ | Bridged | read-only TypeScript adapter |
| MESH-SOL-TX/SECRET/CRYPTO/SIGNER | Deferred | isolated Rust executor; absent from paper and shadow deployments |

## Runtime verification

At the pinned revision:

```text
cargo fmt --all -- --check
cargo test -p mesh-rt env::tests::test_env_args
cargo test -p meshc --test e2e e2e_checked_mul_div
cargo test -p meshc --test e2e e2e_monotonic_duration
cargo test -p meshc --test e2e e2e_bounded_channel
cargo test -p meshc --test e2e e2e_deterministic_random
cargo test -p meshc --test e2e e2e_process_shutdown_signal
cargo test -p meshc --test e2e e2e_process_exit_sets_the_native_status_code
cargo test -p meshc --test e2e e2e_nested_and
```

Collector capability probes cover HTTP, JSON, PostgreSQL, actors, supervisors,
timers, shutdown, and the project-local packages before milestone zero closes.
