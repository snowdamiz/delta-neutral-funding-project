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
JUPITER_API_KEY=replace-with-read-only-api-key \
docker compose up --build
```

That mode combines the Phoenix SOL orderbook and hourly funding record, JitoSOL
stake-pool and mint accounts from Solana RPC, and exact-size Jupiter spot
quotes. Comma-separated `PHOENIX_URLS`, `SOLANA_RPC_URLS`, and `JUPITER_URLS`
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
scripts/check-toolchain.sh
```

The replay gate runs the calm, volatile, liquidity-loss, epoch-boundary, and
deterministic-failure bundles twice and checks their exact outcome hashes.
The toolchain gate additionally verifies the exact clean Mesh checkout and runs
the Mesh, TypeScript, and Rust conformance suites while building their images.

Milestone status and open gates are tracked in
[`docs/implementation-status.md`](docs/implementation-status.md).
