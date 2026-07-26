# JitoSOL qualification

Status: qualified for read-only paper modeling; not approved for live execution.

## Verified mainnet identities

| Item | Address |
|---|---|
| JitoSOL mint | `J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn` |
| Stake pool | `Jito4APyf642JPZPx3hGc6WWJ8zPKtRbRs4P815Awbb` |
| SPL Stake Pool program | `SPoo1Ku8WFXoNDMHPsrGSTSG1Y47rzgn41SLUNakuHy` |
| SPL Token program | `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA` |

JitoSOL has nine decimals. These values must be reverified from on-chain owners
and the official deployment page at shadow and live startup.

## Independent NAV

For `supply_atoms > 0`:

```text
nav_lamports_per_jitosol_token
  = floor(total_pool_lamports * 1_000_000_000 / supply_atoms)
```

The multiplication uses a checked wide intermediate. Pool state, supply, slot,
account owners, and raw payload hash are persisted. The adapter calculation and
the Mesh calculation must agree exactly.

Jito describes rewards as an increasing exchange rate, not a rebasing token.
Reward attribution therefore uses observed NAV changes. A decreasing or
inconsistent rate is recorded and opens a risk event; it is never silently
clamped away.

## Exit behavior

- An executable Jupiter sell quote is the immediate-exit reference.
- Direct withdrawal currently has a 10 bps fee and can take up to one epoch.
- The delayed path remains unavailable for immediate perp margin protection.
- Paper compares both paths, including multi-step fees and capital lockup.

Official sources:

- https://www.jito.network/docs/jitosol/faqs/technical-faqs/
- https://www.jito.network/docs/jitosol/jitosol-liquid-staking/security/deployed-programs/
- https://www.jito.network/docs/jitosol/get-started/unstaking-jitosol-flow/unstaking-overview/
- https://www.jito.network/docs/jitosol/faqs/general-faqs/

