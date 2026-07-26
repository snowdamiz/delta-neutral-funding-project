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
```

Milestone status and open gates are tracked in
[`docs/implementation-status.md`](docs/implementation-status.md).
