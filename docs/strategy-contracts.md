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

## NEGATIVE_FUNDING_REVERSE

- Select only the top qualified market per venue after seven clean days and a
  24-hour average below the configured negative-funding threshold.
- Borrow and sell the spot asset at the executable bid; long the same quantity
  of its perpetual at the executable ask.
- Attribute realized long-perp funding, spot/perp basis, trading costs, and
  variable borrow interest separately.
- Require a fresh, identity-pinned Kamino snapshot, at least 2× target notional
  in available borrow liquidity, and utilization below the configured ceiling.
- Exit on the current observation when borrow APR reaches the absolute funding
  rate, borrow evidence becomes stale or invalid, or borrow liquidity and
  utilization breakers fail. Never average a borrow spike away.
- This contract is paper-only; live use additionally requires on-chain
  obligation health, collateral/liquidation, oracle, and program-authority
  checks listed in `kamino-qualification.md`.

## JITOSOL_NAV_DISCOUNT

- Buy only when the executable JitoSOL ask is below protocol NAV and the
  better of direct redemption and instant exit remains positive after modeled
  costs and the configured risk haircut.
- Positive short funding may improve a genuine discount but never makes a
  zero-discount trade eligible.
- Hedge the purchased quantity at its protocol-NAV SOL equivalent and require
  both JitoSOL and perp exit depth for the full hedge.
- Direct redemption reuses the epoch-aware counterfactual state machine and
  attributes realized discount basis separately from actual cooldown funding.
- Invalid oracle state, decreasing NAV, stale source data, insufficient depth,
  unsafe margin, paused entries, and an unhedged synchronized SOL benchmark
  veto entry.
- This contract is paper-only; direct unstake remains unavailable for
  immediate perp-margin protection and live execution remains unapproved.

## CROSS_VENUE_FUNDING

- Select only the top same-asset pair after seven clean days and at least 24
  distinct realized funding prints per venue in the latest 24 hours.
- Short the higher-realized-funding perpetual and long an equal base quantity
  on the lower-funding venue; predicted rates never create eligibility or P&L.
- Require fresh executable exit depth and valid maintenance rates on both
  venues. Track collateral, maintenance, margin ratio, and liquidation distance
  independently for each leg using the latest venue rate.
- Attribute each venue's realized funding once, both-leg costs, and mark
  divergence separately. Exit when the spread no longer covers costs or mark
  divergence loses more than one week of current carry.
- If either leg cannot be priced and exited, persist a critical risk event,
  enter emergency flatten, and close both legs only when both exits are again
  executable.
- This contract is paper-only; Phoenix is qualified only for read-only paper
  evidence, and a live-capable second venue plus the 30-day gate remain
  mandatory before any execution path can be approved.

## HYPERLIQUID_WALLET_TRACKING

- Index only the explicit cohort stored by the authenticated console wallet
  control; the public API does not enumerate every account. Replacing the
  cohort is atomic, audited, and picked up by the adapter without a restart.
  Normalize positions, leverage, fills, realized P&L, and fees through the
  versioned event boundary.
- Compute fee- and account-drawdown-adjusted wallet scores from evidence
  strictly earlier than the copied fill. Twenty closed decisions are required
  before a wallet can qualify.
- Price paper copies from the adverse executable Hyperliquid book at the local
  fixed notional. Persist measured source-to-copy latency, slippage, and depth;
  never copy the leader's size.
- Paper three modes independently: qualified aggregate direction as a Phase
  1–4 shadow filter, mirror positive-consistency wallets, and fade
  negative-consistency wallets.
- A mode remains pending until 60 days and 20 closed paper decisions exist and
  both the holding-SOL and Phase-1 benchmark paths are available. It passes
  only when its realized return less maximum drawdown beats both benchmark
  scores. No result authorizes live capital.

## Fail-closed conditions

Schema mismatch, integer parse failure, overflow, stale data, source gap, invalid
oracle, missing or stale borrow evidence, leader loss, unbalanced ledger batch,
risk actor failure, adapter identity mismatch, and executor uncertainty all
stop new entries.
