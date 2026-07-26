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

Milestone status and open gates are tracked in
[`docs/implementation-status.md`](docs/implementation-status.md).
