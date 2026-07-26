# Strategy contracts and invariants

## Shared contract

Both portfolios start from the same configured USD capital and may share a
comparison schedule, but never share balances, orders, fills, or ledger batches.
All quantities, prices, rates, fees, and P&L are fixed-scale signed integers.
Every multiplication or division names its rounding policy.

Entry is allowed only when normalized short funding receipt is positive after
fees and haircuts, all source data is fresh and gap-free, an executable exit is
deep enough, margin and liquidation limits pass, and expected net carry remains
positive over the configured holding period.

No state becomes `HEDGED` until confirmed spot and perp quantities reconcile.
An in-flight intent is persisted before any side effect. Duplicate source events
and commands are idempotent. Unknown outcomes pause the portfolio and reconcile
before retry.

## SOL_CONTROL

- Acquire SOL at an executable adverse paper price.
- Short the same SOL-equivalent base quantity on SOL-PERP within delta tolerance.
- P&L components: realized funding, spot/perp basis, execution fees, slippage,
  chain costs, and residual delta.

## JITOSOL_CARRY

- Acquire JitoSOL at an executable adverse paper price.
- Hedge its protocol-NAV SOL equivalent with a short SOL-PERP position.
- Attribute observed NAV accrual separately from market/NAV basis movement.
- Rehedge when reward-driven delta exceeds the configured threshold.
- Veto entry on invalid pool ownership, NAV mismatch, decreasing unexplained
  NAV, stale epoch state, or insufficient JitoSOL exit depth.

## Fail-closed conditions

Schema mismatch, integer parse failure, overflow, stale data, source gap, invalid
oracle, leader loss, unbalanced ledger batch, risk actor failure, adapter
identity mismatch, and executor uncertainty all stop new entries.

