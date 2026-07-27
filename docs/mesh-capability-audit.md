# Mesh capability audit

Candidate Mesh pin: `b0ee2d5626f3374403823bca7cc0703f668dae71`

This audit records the ownership and exit condition for every language boundary.
The TypeScript adapter remains the authoritative paper feed until the applicable
read-only or shadow differential gate qualifies.

| Capability | Classification | Owner | Current bridge | Bridge removal criterion | Status and evidence |
|---|---|---|---|---|---|
| MESH-FIN-001/002 | Runtime plus pure Mesh | Mesh and collector maintainers | None | N/A | Adopted; checked wide arithmetic and nominal finance vectors pass |
| MESH-TIME/TEST | Runtime plus pure Mesh | Mesh and collector maintainers | Explicit event timestamps | Replay and soak clocks remain deterministic | Adopted; monotonic, virtual-time, and deterministic-random proofs pass |
| MESH-ACTOR/PROC | Runtime | Mesh maintainers | None | N/A | Adopted; bounded delivery, drain, signal, GC, and supervisor proofs pass |
| MESH-OBS/METRICS | Pure Mesh plus runtime telemetry | Collector maintainers | PostgreSQL-derived snapshots | Runtime and database views agree under soak | Adopted; bounded metrics and alert checks pass |
| MESH-PROTO | Pure Mesh plus JSON Schema | Collector maintainers | None | N/A | Adopted; shared mutation and conformance vectors pass |
| MESH-BYTES/CODEC/NUM | Runtime/native primitives | Mesh maintainers | None | N/A | Adopted; strict Base58/Base64/hex and checked U64/U128 proofs pass |
| MESH-NATIVE | Package manager/linker | Mesh maintainers | None | N/A | Adopted; native archives are manifest-gated and hash-verified |
| MESH-HTTP/WS | Runtime/stdlib | Mesh maintainers | TypeScript venue clients | Recorded feed differential, bounded soak, and rollback rehearsal pass | Implemented; bounded HTTP and WSS proofs pass, bridge retained |
| MESH-BORSH/ANCHOR/SOL-READ | Reusable Mesh/native packages | Mesh maintainers | TypeScript protocol adapter | Fixture, replay, live read-only differential, bounded soak, and rollback pass | Implemented; native JitoSOL NAV/epoch/slot proofs pass, bridge retained |
| MESH-SOL-TX | Reusable Mesh package | Mesh maintainers | Adapter/executor shadow builder | Credentialed exact-action simulation differential and rollback pass | Candidate implemented in `mesh-solana` 0.2: legacy/v0/ALT serialization, recent blockhashes, compute budget, SPL/ATA, unsigned simulation, response parsing, and byte-free allowlist reports; networkless collector proof passes |
| MESH-SECRET/CRYPTO/SIGNER | Deferred native/security work | Security review owner | Isolated signer | Independent secret-memory, crypto, policy, and signer review plus explicit operator approval | Deliberately absent; no signer is reachable and no submit API exists |

## Candidate acceptance evidence

- Mesh debug/release compilation and retained `e2e_solana_read_package` proof.
- Collector Docker gate: all 21 Mesh suites, including 10 transaction tests.
- Networkless `scripts/check-native-solana-instruction.sh` proof with
  `signerReachable=false`, `submit=false`, and no unsigned transaction bytes.
- Public package contract versioned as `mesh-solana` 0.2.
- Rollback remains the prior pinned Mesh/application image pair; no database
  migration or strategy semantic change is required.

Performance, live differential, and rollback rehearsal remain adoption gates,
not reasons to expose signing or submission.
